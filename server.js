// ============================================================
// KIGHMU PANEL v2 - Backend complet
// ============================================================
'use strict';

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });

const express   = require('express');
const mysql     = require('mysql2/promise');
const bcrypt    = require('bcryptjs');
const jwt       = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const helmet    = require('helmet');
const cors      = require('cors');
const rateLimit = require('express-rate-limit');
const cron      = require('node-cron');
const si        = require('systeminformation');
const fs        = require('fs');
const { exec }  = require('child_process');
const crypto    = require('crypto');

const REQUIRED_ENV = ['DB_USER', 'DB_PASSWORD', 'DB_NAME', 'JWT_SECRET'];
const missing = REQUIRED_ENV.filter(k => !process.env[k]);
if (missing.length) {
  console.error(`[FATAL] Variables .env manquantes : ${missing.join(', ')}`);
  process.exit(1);
}

const REPORT_SECRET_FILE = path.join(__dirname, '.report_secret');
const ENV_FILE = path.join(__dirname, '.env');
let REPORT_SECRET = process.env.REPORT_SECRET;
if (!REPORT_SECRET) {
  try { REPORT_SECRET = fs.readFileSync(REPORT_SECRET_FILE, 'utf8').trim(); } catch {}
  if (!REPORT_SECRET) {
    REPORT_SECRET = crypto.randomBytes(32).toString('hex');
    fs.writeFileSync(REPORT_SECRET_FILE, REPORT_SECRET, { mode: 0o600 });
    try { fs.appendFileSync(ENV_FILE, `\nREPORT_SECRET=${REPORT_SECRET}\n`); } catch {}
    console.log('[SECRET] REPORT_SECRET genere et ajoute au .env');
  }
}

function genNonce() { return crypto.randomBytes(16).toString('base64url'); }

// ============================================================
// VALIDATION & SANITIZATION HELPERS
// ============================================================
const USERNAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_-]{2,31}$/;
function validateUsername(u) { return typeof u === 'string' && u.length <= 32 && USERNAME_RE.test(u); }
function validateLen(v, max) { return typeof v === 'string' && v.length <= max; }
function escapeShell(arg) { return `'${String(arg).replace(/'/g, "'\\''")}'`; }
function sanitizeLog(obj) {
  if (!obj || typeof obj !== 'object') return obj;
  const sensitive = ['password','pass','token','secret','hash','authorization'];
  const clone = Array.isArray(obj) ? [...obj] : { ...obj };
  for (const k of Object.keys(clone)) {
    if (sensitive.some(s => k.toLowerCase().includes(s))) clone[k] = '***';
    else if (typeof clone[k] === 'object' && clone[k] !== null) clone[k] = sanitizeLog(clone[k]);
  }
  return clone;
}

const app = express();

let db;
async function initDB() {
  try {
    const pool = mysql.createPool({
      host:               process.env.DB_HOST     || '127.0.0.1',
      port:           parseInt(process.env.DB_PORT || '3306'),
      database:           process.env.DB_NAME,
      user:               process.env.DB_USER,
      password:           process.env.DB_PASSWORD,
      waitForConnections: true,
      connectionLimit:    20,
      queueLimit:         0,
      enableKeepAlive:    true,
      keepAliveInitialDelay: 0,
      connectTimeout:     10000,
    });
    pool.on('error', async (err) => {
      console.error('[DB] Pool error:', err.message);
    });
    const conn = await pool.getConnection();
    await conn.ping();
    conn.release();
    db = pool;
    console.log(`[DB] Connexion MySQL OK → ${process.env.DB_NAME}@${process.env.DB_HOST || '127.0.0.1'}`);
    return true;
  } catch (e) {
    console.error(`[DB] ERREUR connexion MySQL : ${e.message}`);
    return false;
  }
}

async function dbHealthCheck() {
  if (!db) return false;
  try {
    const conn = await db.getConnection();
    await conn.ping();
    conn.release();
    return true;
  } catch {
    console.error('[DB] Health check FAILED - tentative reconnexion...');
    try { await initDB(); } catch (e) { console.error('[DB] Reconnexion echouee:', e.message); }
    return false;
  }
}

// ── NONCE generator middleware ───────────────────────────────
const nonceMiddleware = (req, res, next) => {
  req.nonce = genNonce();
  res.locals.nonce = req.nonce;
  next();
};
app.use(nonceMiddleware);

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", (req) => `'nonce-${req.nonce}'`, 'https://cdnjs.cloudflare.com', 'https://cdn.jsdelivr.net'],
      scriptSrcAttr: ["'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com', 'https://cdnjs.cloudflare.com'],
      imgSrc: ["'self'", "data:"],
      connectSrc: ["'self'", 'https://fonts.googleapis.com'],
      fontSrc: ["'self'", 'https://fonts.gstatic.com', 'https://cdnjs.cloudflare.com'],
      objectSrc: ["'none'"],
      mediaSrc: ["'none'"],
      frameSrc: ["'none'"],
      formAction: ["'self'"],
      baseUri: ["'self'"],
    }
  },
  referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
  hsts: { maxAge: 63072000, preload: true, includeSubDomains: true },
  noSniff: true,
  xssFilter: true,
}));

const CORS_ORIGIN = process.env.CORS_ORIGIN || null;
app.use(cors({
  origin: CORS_ORIGIN
    ? CORS_ORIGIN.split(',').map(s => s.trim())
    : function (origin, cb) {
        if (!origin || origin === 'null') return cb(null, false);
        cb(null, origin);
      },
}));

app.use(express.json({ limit: '10kb' }));
app.set('trust proxy', 1);

const globalLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 500, standardHeaders: true, legacyHeaders: false });
app.use(globalLimiter);

const loginLimiter    = rateLimit({ windowMs: 15 * 60 * 1000, max: 20, standardHeaders: true, legacyHeaders: false, message: { error: 'Trop de tentatives de connexion. Réessayez plus tard.' } });
const writeLimiter    = rateLimit({ windowMs: 15 * 60 * 1000, max: 60, standardHeaders: true, legacyHeaders: false, message: { error: 'Trop de requetes. Reessayez plus tard.' } });
const authWriteLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 30, standardHeaders: true, legacyHeaders: false, message: { error: 'Trop de requetes. Reessayez plus tard.' } });

app.get('/health', (req, res) => {
  res.json({ status: db ? 'ok' : 'db_error', uptime: Math.floor(process.uptime()) + 's', db: db ? 'connected' : 'disconnected', time: new Date().toISOString() });
});

app.use('/api', (req, res, next) => {
  if (!db) return res.status(503).json({ error: 'Base de données non connectée. Vérifiez MySQL.' });
  next();
});

const FIELD_MAX = { username: 32, password: 128, note: 500, tunnel_type: 32 };
function validateFields(body) {
  for (const [field, maxLen] of Object.entries(FIELD_MAX)) {
    if (body[field] !== undefined && body[field] !== null) {
      if (typeof body[field] !== 'string') continue;
      if (body[field].length > maxLen) {
        throw new Error(`Le champ "${field}" ne doit pas depasser ${maxLen} caracteres`);
      }
    }
  }
}
const inputValidation = (req, res, next) => {
  try {
    if (req.body && typeof req.body === 'object') validateFields(req.body);
    next();
  } catch (e) { res.status(400).json({ error: e.message }); }
};
app.use('/api', inputValidation);

const FRONTEND = path.join(__dirname, 'frontend');
if (!fs.existsSync(FRONTEND)) {
  console.error(`[STATIC] ERREUR : dossier frontend introuvable → ${FRONTEND}`);
}

// ============================================================
// BRUTE-FORCE
// ============================================================
const MAX_ATT   = parseInt(process.env.MAX_LOGIN_ATTEMPTS   || '5');
const BLOCK_MIN = parseInt(process.env.BLOCK_DURATION_MINUTES || '30');

async function checkBruteForce(ip) {
  try {
    const [rows] = await db.query('SELECT * FROM login_attempts WHERE ip_address = ?', [ip]);
    if (!rows.length) return null;
    const r = rows[0];
    if (r.blocked_until && new Date(r.blocked_until) > new Date()) {
      const mins = Math.ceil((new Date(r.blocked_until) - new Date()) / 60000);
      return `IP bloquée. Réessayez dans ${mins} min.`;
    }
    if (r.attempts >= MAX_ATT) {
      const until = new Date(Date.now() + BLOCK_MIN * 60000);
      await db.query('UPDATE login_attempts SET blocked_until=?, last_attempt=NOW() WHERE ip_address=?', [until, ip]);
      return `Trop de tentatives. IP bloquée ${BLOCK_MIN} minutes.`;
    }
    return null;
  } catch { return null; }
}
async function failAttempt(ip) {
  try {
    const [r] = await db.query('SELECT id FROM login_attempts WHERE ip_address=?', [ip]);
    if (r.length) await db.query('UPDATE login_attempts SET attempts=attempts+1, last_attempt=NOW() WHERE ip_address=?', [ip]);
    else await db.query('INSERT INTO login_attempts (ip_address) VALUES (?)', [ip]);
  } catch {}
}
async function clearAttempts(ip) {
  try { await db.query('DELETE FROM login_attempts WHERE ip_address=?', [ip]); } catch {}
}

// ============================================================
// JWT MIDDLEWARE
// ============================================================
function auth(roles = []) {
  return async (req, res, next) => {
    try {
      const header = req.headers.authorization || '';
      const token  = header.startsWith('Bearer ') ? header.slice(7) : null;
      if (!token) return res.status(401).json({ error: 'Token manquant' });
      const decoded = jwt.verify(token, process.env.JWT_SECRET);
      if (roles.length && !roles.includes(decoded.role))
        return res.status(403).json({ error: 'Accès refusé' });
      if (decoded.role === 'reseller') {
        const [[r]] = await db.query('SELECT is_active, expires_at FROM resellers WHERE id=?', [decoded.id]);
        if (!r || !r.is_active) return res.status(401).json({ error: 'Compte désactivé' });
        if (new Date(r.expires_at) < new Date()) {
          await cleanupReseller(decoded.id);
          await db.query('DELETE FROM resellers WHERE id=?', [decoded.id]);
          return res.status(401).json({ error: 'Compte expiré — accès révoqué' });
        }
      }
      req.user = decoded;
      next();
    } catch (e) {
      return res.status(401).json({ error: 'Token invalide ou expiré' });
    }
  };
}

// ============================================================
// LOGGER
// ============================================================
async function log(actorType, actorId, action, targetType, targetId, details, ip) {
  try {
    await db.query(
      'INSERT INTO activity_logs (actor_type,actor_id,action,target_type,target_id,details,ip_address) VALUES (?,?,?,?,?,?,?)',
      [actorType, actorId, action, targetType||null, targetId||null, details ? JSON.stringify(sanitizeLog(details)) : null, ip||null]
    );
  } catch {}
}

// ============================================================
// TUNNEL MANAGER
// ============================================================
const execAsync = (cmd) => new Promise((res, rej) =>
  exec(cmd, { timeout: 10000 }, (e, out, err) => e ? rej(new Error(err || e.message)) : res(out))
);
const readJson  = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const writeJson = (p, d) => { try { fs.writeFileSync(p, JSON.stringify(d, null, 2)); } catch(e) { console.error(`[TUNNEL] writeJson(${p}):`, e.message); } };

async function restartService(svc) {
  try { await execAsync(`systemctl restart ${svc}`); return true; }
  catch (e) { console.error(`[TUNNEL] restart ${svc}:`, e.message); return false; }
}

// ── Synchronise /etc/xray/users.json avec les créations/suppressions du panel ──
// Ce fichier est lu par menu_6.sh pour afficher et gérer les utilisateurs.
// Format attendu : { "vmess": [...], "vless": [...], "trojan": [...] }
// Chaque entrée : { uuid, email, name, tag, limit_gb, used_gb, expire }
function _xraySyncUsersJson(username, proto, uuid, action) {
  const usersPath = '/etc/xray/users.json';
  try {
    let data = readJson(usersPath) || { vmess: [], vless: [], trojan: [] };
    if (!data.vmess)  data.vmess  = [];
    if (!data.vless)  data.vless  = [];
    if (!data.trojan) data.trojan = [];

    if (action === 'add') {
      // Vérifier doublon
      const already = data[proto]?.some(u => u.uuid === uuid || u.email === username || u.name === username);
      if (!already) {
        const tag = `${proto}_${username}_${uuid.slice(0, 8)}`;
        data[proto].push({
          uuid,
          email:    tag,
          name:     username,
          tag:      tag,
          limit_gb: 0,
          used_gb:  0,
          expire:   'N/A'
        });
        writeJson(usersPath, data);
        console.log(`[XRAY-SYNC] users.json : ajout ${proto}/${username}`);
      }
    } else if (action === 'remove') {
      const before = (data[proto] || []).length;
      data[proto] = (data[proto] || []).filter(u => u.uuid !== uuid && u.name !== username && u.email !== username);
      if (data[proto].length !== before) {
        writeJson(usersPath, data);
        console.log(`[XRAY-SYNC] users.json : suppression ${proto}/${username}`);
      }
    }
  } catch (e) {
    console.error(`[XRAY-SYNC] Erreur sync users.json (${action} ${username}):`, e.message);
  }
}

function xrayAdd(username, protocol, uuid) {
  const cfgPath = process.env.XRAY_CONFIG || '/etc/xray/config.json';
  const cfg = readJson(cfgPath);
  if (!cfg) return { ok: false, msg: `config xray introuvable : ${cfgPath}` };

  // Trouver TOUS les inbounds du protocole (vmess-ws-tls, vmess-grpc, vmess-ws-ntls, etc.)
  const proto = protocol.toLowerCase();
  const inbounds = cfg.inbounds?.filter(i => i.protocol === proto) || [];
  if (!inbounds.length) return { ok: false, msg: `inbound ${protocol} introuvable dans xray config` };

  let added = 0;
  for (const inb of inbounds) {
    if (!inb.settings) inb.settings = {};
    if (!inb.settings.clients) inb.settings.clients = [];

    // Ne pas dupliquer si déjà présent (par uuid ou email/password)
    const alreadyExists = proto === 'trojan'
      ? inb.settings.clients.some(c => c.password === uuid || c.email === username)
      : inb.settings.clients.some(c => c.id === uuid || c.email === username);

    if (alreadyExists) continue;

    // IMPORTANT : pour Trojan, password = uuid (cohérent avec menu_6.sh)
    const client = proto === 'trojan'
      ? { password: uuid, level: 0, email: username }
      : { id: uuid, level: 0, email: username, alterId: proto === 'vmess' ? 0 : undefined };

    // Supprimer les clés undefined pour un JSON propre
    Object.keys(client).forEach(k => client[k] === undefined && delete client[k]);

    inb.settings.clients.push(client);
    added++;
  }

  writeJson(cfgPath, cfg);
  console.log(`[XRAY] xrayAdd(${username}, ${proto}): ${added} inbound(s) mis à jour sur ${inbounds.length}`);

  // ── Synchroniser /etc/xray/users.json (lu par menu_6.sh) ────────────────
  _xraySyncUsersJson(username, proto, uuid, 'add');

  return { ok: true, inbounds_updated: added };
}

function xrayRemove(username, protocol, uuid) {
  const cfgPath = process.env.XRAY_CONFIG || '/etc/xray/config.json';
  const cfg = readJson(cfgPath);
  if (!cfg) return;

  // Supprimer le client dans TOUS les inbounds du protocole
  const proto = protocol.toLowerCase();
  const inbounds = cfg.inbounds?.filter(i => i.protocol === proto) || [];
  for (const inb of inbounds) {
    if (!inb?.settings?.clients) continue;
    if (proto === 'trojan') {
      // Trojan : password = uuid, email = username
      inb.settings.clients = inb.settings.clients.filter(
        c => c.password !== uuid && c.email !== username
      );
    } else {
      // VMess / VLESS : id = uuid, email = username
      inb.settings.clients = inb.settings.clients.filter(
        c => c.id !== uuid && c.email !== username
      );
    }
  }
  writeJson(cfgPath, cfg);
  console.log(`[XRAY] xrayRemove(${username}, ${proto}): supprimé dans ${inbounds.length} inbound(s)`);

  // ── Synchroniser /etc/xray/users.json (lu par menu_6.sh) ────────────────
  _xraySyncUsersJson(username, proto, uuid, 'remove');
}

// ============================================================
// SSH NFTABLES — comptage trafic par UID
// ============================================================
const SSH_DELTA_DIR = '/var/lib/kighmu/ssh-counters';
try { fs.mkdirSync(SSH_DELTA_DIR, { recursive: true }); } catch {}
const NFT = '/usr/sbin/nft';

async function ensureKighmuTable() {
  await execAsync('bash /usr/local/bin/init-nftables-kighmu.sh');
}

async function sshNftablesAdd(username) {
  try {
    await ensureKighmuTable();
    if (!validateUsername(username)) { console.error(`[SSH-RULES] skip: username invalide: ${username}`); return; }
    const safeUser = escapeShell(username);
    const uidRaw = await execAsync(`id -u ${safeUser} 2>/dev/null`);
    const uid = uidRaw.trim();
    if (!uid || !/^\d+$/.test(uid)) return;
    const tag = `ssh_${uid}`;
    const exists = await execAsync(`${NFT} list counter inet kighmu ${tag}_out 2>/dev/null`).catch(() => '');
    if (exists) return;
    await execAsync(`${NFT} add counter inet kighmu ${tag}_out`);
    await execAsync(`${NFT} add counter inet kighmu ${tag}_in`);
    await execAsync(`${NFT} add rule inet kighmu output skuid ${uid} ct state new ct mark set ${uid} comment \"${tag}\"`);
    await execAsync(`${NFT} add rule inet kighmu output skuid ${uid} counter name \"${tag}_out\" accept comment \"${tag}\"`);
    await execAsync(`${NFT} add rule inet kighmu input ct mark ${uid} counter name \"${tag}_in\" accept comment \"${tag}\"`);
    const curOut = await _readNftablesCounter(`${tag}_out`);
    const curIn  = await _readNftablesCounter(`${tag}_in`);
    fs.writeFileSync(`${SSH_DELTA_DIR}/${username}.out`, String(curOut));
    fs.writeFileSync(`${SSH_DELTA_DIR}/${username}.in`,  String(curIn));
    console.log(`[SSH-RULES] regles nftables creees pour ${username} (uid=${uid})`);
  } catch (e) {
    console.error(`[SSH-RULES] Erreur sshNftablesAdd(${username}):`, e.message);
  }
}

async function sshNftablesRemove(username) {
  try {
    if (!validateUsername(username)) { console.error(`[SSH-RULES] skip remove: username invalide: ${username}`); return; }
    const safeUser = escapeShell(username);
    const uidRaw = await execAsync(`id -u ${safeUser} 2>/dev/null`).catch(() => '');
    const uid = uidRaw.trim();
    if (uid && /^\d+$/.test(uid)) {
      const tag = `ssh_${uid}`;
      await execAsync(`${NFT} delete counter inet kighmu ${tag}_out 2>/dev/null || true`);
      await execAsync(`${NFT} delete counter inet kighmu ${tag}_in 2>/dev/null || true`);
      for (const chain of ['output', 'input']) {
        const handle = await execAsync(
          `${NFT} -a list chain inet kighmu ${chain} 2>/dev/null | grep 'comment "${tag}"' | grep -oP 'handle \\\\K\\\\d+' | tail -1`
        ).catch(() => '');
        if (handle && /^\d+$/.test(handle.trim())) {
          await execAsync(`${NFT} delete rule inet kighmu ${chain} handle ${handle.trim()}`);
        }
      }
    }
    try { fs.unlinkSync(`${SSH_DELTA_DIR}/${username}.out`); } catch {}
    try { fs.unlinkSync(`${SSH_DELTA_DIR}/${username}.in`);  } catch {}
    console.log(`[SSH-RULES] regles supprimees pour ${username}`);
  } catch (e) {
    console.error(`[SSH-RULES] Erreur sshNftablesRemove(${username}):`, e.message);
  }
}

async function _readNftablesCounter(name) {
  try {
    const out = await execAsync(`${NFT} list counter inet kighmu ${name} 2>/dev/null`);
    const m = out.match(/bytes\s+(\d+)/);
    return m ? parseInt(m[1]) : 0;
  } catch { return 0; }
}

// ── Synchroniser udp-custom/config.json avec /etc/kighmu/users.list ──
async function syncUdpCustom() {
  const udpCfgPath  = '/etc/udp-custom/config.json';
  const userFile    = '/etc/kighmu/users.list';
  if (!fs.existsSync(udpCfgPath) || !fs.existsSync(userFile)) return;
  const cfg = JSON.parse(fs.readFileSync(udpCfgPath, 'utf8'));
  const passwords = fs.readFileSync(userFile, 'utf8')
    .split('\n')
    .filter(l => l.trim())
    .map(l => l.split('|')[1])
    .filter(Boolean);
  cfg.auth = cfg.auth || {};
  cfg.auth.config = passwords;
  fs.writeFileSync(udpCfgPath, JSON.stringify(cfg, null, 2));
  await execAsync('systemctl restart udp-custom').catch(() => {});
  console.log(`[UDP-CUSTOM] ${passwords.length} mots de passe synchronisés`);
}

async function sshAdd(username, password, expiryDate) {
  const os  = require('os');
  const path = require('path');
  const tmp  = path.join(os.tmpdir(), `kighmu_ssh_${Date.now()}_${Math.random().toString(36).slice(2)}.sh`);

  try {
    const exp = new Date(expiryDate).toISOString().split('T')[0];
    const readF = p => { try { return fs.readFileSync(p, 'utf8').trim(); } catch { return ''; } };

    // Lire DOMAIN (priorité : domaine réel sur IP brute)
    const parseKV2 = (p, key) => {
      try {
        const txt = fs.readFileSync(p, 'utf8');
        const m = txt.match(new RegExp('^' + key + '=(.+)$', 'm'));
        return m && m[1].trim() ? m[1].trim() : '';
      } catch { return ''; }
    };
    const isIP = v => /^\d+\.\d+\.\d+\.\d+$/.test(v);
    const getDomain = () => {
      const sources = [
        readF('/etc/kighmu/domain.txt'),
        parseKV2(`${process.env.HOME || '/root'}/.kighmu_info`, 'DOMAIN'),
        parseKV2('/opt/kighmu-panel/.install_info', 'DOMAIN'),
        readF('/etc/xray/domain'),
        readF('/tmp/.xray_domain'),
      ];
      // Préférer un vrai domaine (non-IP) en premier
      return sources.find(v => v && !isIP(v))
          || sources.find(v => v) // sinon première valeur non vide
          || '';
    };

    const domain    = getDomain();
    const slowdnsNs = readF('/etc/slowdns/ns.conf') || readF('/etc/slowdns_v2ray/ns.conf') || '';
    let hostIp = '';
    try { const nets = await si.networkInterfaces(); const eth = nets.find(n => !n.internal && n.ip4); hostIp = eth ? eth.ip4 : ''; } catch {}
    const limite = Math.max(1, Math.round((new Date(exp) - new Date()) / 86400000));

    const bannerPath  = '/etc/ssh/sshd_banner';
    const kighmuDir   = '/etc/kighmu';
    const userFile    = `${kighmuDir}/users.list`;
    // zivpnUF/hyUF supprimés — SSH n'interagit plus avec ZIVPN/Hysteria

    // ── Script bash unique, identique à menu1.sh ────────────────
    // Le mot de passe est injecté via heredoc → aucun problème de
    // caractères spéciaux ($, !, ", `, \, espaces, etc.)
    const script = `#!/bin/bash
# Généré par Kighmu Panel — création utilisateur SSH
set -e

USERNAME="${username}"
EXPIRE_DATE="${exp}"
BANNER_PATH="${bannerPath}"
USER_HOME="/home/${username}"

# ── 1. Créer l'utilisateur système (identique à menu1.sh) ──
if id "$USERNAME" &>/dev/null; then
  echo "[SSH] Utilisateur $USERNAME existe déjà — mise à jour mot de passe"
else
  useradd -m -s /bin/bash "$USERNAME"
  echo "[SSH] Utilisateur $USERNAME créé"
fi

# ── 2. Définir le mot de passe via heredoc (sûr pour tous caractères) ──
chpasswd << 'CHPASSWD_EOF'
${username}:${password}
CHPASSWD_EOF

# ── 3. Date d'expiration ──
chage -E "$EXPIRE_DATE" "$USERNAME"

# ── 4. Répertoire home + .bashrc avec banner ──
if [ ! -d "$USER_HOME" ]; then
  mkdir -p "$USER_HOME"
  chown "$USERNAME":"$USERNAME" "$USER_HOME"
fi

cat > "$USER_HOME/.bashrc" << 'BASHRC_EOF'
# Affichage du banner Kighmu VPS Manager
if [ -f ${bannerPath} ]; then
    cat ${bannerPath}
fi
BASHRC_EOF

chown "$USERNAME":"$USERNAME" "$USER_HOME/.bashrc"
chmod 644 "$USER_HOME/.bashrc"

echo "[SSH] Utilisateur $USERNAME configuré avec succès"
`;

    fs.writeFileSync(tmp, script, { mode: 0o700 });
    await execAsync(`bash ${tmp}`);

    // ── users.list ───────────────────────────────────────────────
    try {
      if (!fs.existsSync(kighmuDir)) fs.mkdirSync(kighmuDir, { recursive: true });
      let lines = fs.existsSync(userFile)
        ? fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`))
        : [];
      lines.push(`${username}|${password}|${limite}|${exp}|${hostIp}|${domain}|${slowdnsNs}`);
      fs.writeFileSync(userFile, lines.join('\n') + '\n');
      fs.chmodSync(userFile, 0o600);
    } catch (e2) { console.error('[SSH] Erreur users.list:', e2.message); }

    // NOTE: ZIVPN et Hysteria sont des tunnels UDP indépendants.
    // Un user ssh-multi/ssh-ws/etc. ne doit PAS être ajouté dans ces configs.
    // Seuls les tunnel_type 'udp-zivpn' et 'udp-hysteria' utilisent ces services.
    await sshNftablesAdd(username);
    return { ok: true };

  } catch (e) {
    console.error(`[SSH] sshAdd ERREUR pour ${username}:`, e.message);
    return { ok: false, msg: e.message };
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}

async function sshRemove(username) {
  try {
    await sshNftablesRemove(username);
    if (!validateUsername(username)) { console.error(`[SSH] skip remove: username invalide: ${username}`); return; }
    const safeUser = escapeShell(username);
    await execAsync(`userdel -r ${safeUser} 2>/dev/null || true`);
    // Nettoyage /etc/kighmu/users.list
    try {
      const userFile = '/etc/kighmu/users.list';
      if (fs.existsSync(userFile)) {
        const lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
        fs.writeFileSync(userFile, lines.join('\n') + '\n');
      }
    } catch (e2) { console.error('[SSH] Erreur suppression /etc/kighmu/users.list:', e2.message); }
    // ── Synchroniser udp-custom après suppression ────────────────
    try { await syncUdpCustom(); } catch (e3) { console.error('[SSH] udp-custom sync:', e3.message); }
    // NOTE: Ne pas toucher ZIVPN/Hysteria — ce sont des tunnels UDP indépendants.
  } catch {}
}

async function sshLock(username) {
  try {
    if (!validateUsername(username)) return { ok: false, msg: 'username invalide' };
    const safeUser = escapeShell(username);
    await execAsync(`passwd -l ${safeUser} 2>/dev/null || true`);
    return { ok: true };
  } catch (e) { return { ok: false, msg: 'erreur lors du verrouillage' }; }
}

async function sshUnlock(username) {
  try {
    if (!validateUsername(username)) return { ok: false, msg: 'username invalide' };
    const safeUser = escapeShell(username);
    await execAsync(`passwd -u ${safeUser} 2>/dev/null || true`);
    return { ok: true };
  } catch (e) { return { ok: false, msg: 'erreur lors du deverrouillage' }; }
}

// ── Recrée les règles nftables SSH pour tous les clients actifs après reboot ──
async function syncAllSshRules() {
  try {
    const [rows] = await db.query(
      `SELECT username FROM clients WHERE tunnel_type LIKE 'ssh-%' AND is_active=1 AND expires_at >= NOW()`
    );
    let ok = 0;
    for (const r of rows) {
      try { await sshNftablesAdd(r.username); ok++; } catch {}
    }
    console.log(`[SSH-RULES] Sync apres reboot : ${ok}/${rows.length} regles nftables restaurees`);
  } catch (e) {
    console.error('[SSH-RULES] Sync error:', e.message);
  }
}

function zivpnAdd(username, password, expiresAt) {
  try {
    const userFile = '/etc/zivpn/users.list';
    const cfgFile  = '/etc/zivpn/config.json';
    if (!fs.existsSync('/etc/zivpn')) return { ok: false, msg: 'ZIVPN non installé (/etc/zivpn manquant)' };
    const expire = expiresAt ? new Date(expiresAt).toISOString().split('T')[0] : '2099-12-31';
    let lines = [];
    if (fs.existsSync(userFile)) {
      lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    }
    lines.push(`${username}|${password}|${expire}`);
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    fs.chmodSync(userFile, 0o600);
    _zivpnSyncConfig(userFile, cfgFile);
    return { ok: true };
  } catch (e) { return { ok: false, msg: e.message }; }
}

function zivpnRemove(username) {
  try {
    const userFile = '/etc/zivpn/users.list';
    const cfgFile  = '/etc/zivpn/config.json';
    if (!fs.existsSync(userFile)) return;
    const lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    _zivpnSyncConfig(userFile, cfgFile);
  } catch {}
}

function _zivpnSyncConfig(userFile, cfgFile) {
  try {
    if (!fs.existsSync(cfgFile)) return;
    const today = new Date().toISOString().split('T')[0];
    const passwords = fs.readFileSync(userFile, 'utf8').split('\n')
      .filter(l => l.trim()).map(l => l.split('|'))
      .filter(p => p.length >= 3 && p[2] >= today).map(p => p[1])
      .filter((v, i, a) => a.indexOf(v) === i);
    const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
    if (!cfg.auth) cfg.auth = { mode: 'passwords', config: [] };
    cfg.auth.config = passwords.length > 0 ? passwords : ['zi'];
    fs.writeFileSync(cfgFile, JSON.stringify(cfg, null, 2));
  } catch (e) { console.error('[ZIVPN] sync config error:', e.message); }
}

function hysteriaAdd(username, password, expiresAt) {
  try {
    const userFile = '/etc/hysteria/users.txt';
    const cfgFile  = '/etc/hysteria/config.json';
    if (!fs.existsSync('/etc/hysteria')) return { ok: false, msg: 'Hysteria non installé (/etc/hysteria manquant)' };
    const expire = expiresAt ? new Date(expiresAt).toISOString().split('T')[0] : '2099-12-31';
    let lines = [];
    if (fs.existsSync(userFile)) {
      lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    }
    lines.push(`${username}|${password}|${expire}`);
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    fs.chmodSync(userFile, 0o600);
    _hysteriaSyncConfig(userFile, cfgFile);
    return { ok: true };
  } catch (e) { return { ok: false, msg: e.message }; }
}

function hysteriaRemove(username) {
  try {
    const userFile = '/etc/hysteria/users.txt';
    const cfgFile  = '/etc/hysteria/config.json';
    if (!fs.existsSync(userFile)) return;
    const lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    _hysteriaSyncConfig(userFile, cfgFile);
  } catch {}
}

function _hysteriaSyncConfig(userFile, cfgFile) {
  try {
    if (!fs.existsSync(cfgFile)) return;
    const today = new Date().toISOString().split('T')[0];
    const passwords = fs.readFileSync(userFile, 'utf8').split('\n')
      .filter(l => l.trim()).map(l => l.split('|'))
      .filter(p => p.length >= 3 && p[2] >= today).map(p => p[1])
      .filter((v, i, a) => a.indexOf(v) === i);
    const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
    if (!cfg.auth) cfg.auth = { mode: 'passwords', config: [] };
    cfg.auth.config = passwords.length > 0 ? passwords : ['zi'];
    fs.writeFileSync(cfgFile, JSON.stringify(cfg, null, 2));
  } catch (e) { console.error('[HYSTERIA] sync config error:', e.message); }
}

function v2rayAdd(username, uuid) {
  const cfgPath = process.env.V2RAY_CONFIG || '/etc/v2ray/config.json';
  const cfg = readJson(cfgPath);
  if (!cfg) return { ok: false, msg: `config v2ray introuvable : ${cfgPath}` };
  const inb = cfg.inbounds?.find(i => i.protocol === 'vless' || i.protocol === 'vmess');
  if (!inb?.settings?.clients) return { ok: false, msg: 'inbound vless/vmess introuvable dans config v2ray' };
  if (inb.settings.clients.some(c => c.id === uuid || c.email === username)) return { ok: true };
  const client = { id: uuid, email: username };
  if (inb.protocol === 'vmess') client.alterId = 0;
  inb.settings.clients.push(client);
  writeJson(cfgPath, cfg);
  return { ok: true };
}

function v2rayRemove(username, uuid) {
  const cfgPath = process.env.V2RAY_CONFIG || '/etc/v2ray/config.json';
  const cfg = readJson(cfgPath);
  if (!cfg) return;
  const inb = cfg.inbounds?.find(i => i.protocol === 'vless' || i.protocol === 'vmess');
  if (!inb?.settings?.clients) return;
  inb.settings.clients = inb.settings.clients.filter(c => c.id !== uuid && c.email !== username);
  writeJson(cfgPath, cfg);
}

// ============================================================
// ZIVPN / HYSTERIA — BLOCK / RESTORE (quota)
// Au blocage quota : sauvegarde le password dans .blocked
// Au déblocage : restaure depuis .blocked ou depuis la DB
// ============================================================

function zivpnBlockSave(username) {
  try {
    const userFile    = '/etc/zivpn/users.list';
    const cfgFile     = '/etc/zivpn/config.json';
    const blockedDir  = '/etc/zivpn/blocked';
    if (!fs.existsSync(userFile)) return;
    if (!fs.existsSync(blockedDir)) fs.mkdirSync(blockedDir, { recursive: true });
    const lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim());
    const userLine = lines.find(l => l.startsWith(`${username}|`));
    if (!userLine) return;
    fs.writeFileSync(`${blockedDir}/${username}.blocked`, userLine);
    fs.chmodSync(`${blockedDir}/${username}.blocked`, 0o600);
    const newLines = lines.filter(l => !l.startsWith(`${username}|`));
    fs.writeFileSync(userFile, newLines.join('\n') + '\n');
    _zivpnSyncConfig(userFile, cfgFile);
    console.log(`[ZIVPN-BLOCK] ${username} bloqué (password sauvegardé)`);
  } catch (e) { console.error(`[ZIVPN-BLOCK] Erreur blockSave(${username}):`, e.message); }
}

function zivpnBlockRestore(username, password, expires_at) {
  try {
    const userFile    = '/etc/zivpn/users.list';
    const cfgFile     = '/etc/zivpn/config.json';
    const blockedDir  = '/etc/zivpn/blocked';
    const blockedFile = `${blockedDir}/${username}.blocked`;
    let userLine = null;
    if (fs.existsSync(blockedFile)) {
      userLine = fs.readFileSync(blockedFile, 'utf8').trim();
      fs.unlinkSync(blockedFile);
    }
    if (!userLine) {
      const expire = expires_at ? new Date(expires_at).toISOString().split('T')[0] : '2099-12-31';
      userLine = `${username}|${password}|${expire}`;
    }
    let lines = [];
    if (fs.existsSync(userFile))
      lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    lines.push(userLine);
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    fs.chmodSync(userFile, 0o600);
    _zivpnSyncConfig(userFile, cfgFile);
    console.log(`[ZIVPN-BLOCK] ${username} débloqué`);
  } catch (e) { console.error(`[ZIVPN-BLOCK] Erreur blockRestore(${username}):`, e.message); }
}

function hysteriaBlockSave(username) {
  try {
    const userFile   = '/etc/hysteria/users.txt';
    const cfgFile    = '/etc/hysteria/config.json';
    const blockedDir = '/etc/hysteria/blocked';
    if (!fs.existsSync(userFile)) return;
    if (!fs.existsSync(blockedDir)) fs.mkdirSync(blockedDir, { recursive: true });
    const lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim());
    const userLine = lines.find(l => l.startsWith(`${username}|`));
    if (!userLine) return;
    fs.writeFileSync(`${blockedDir}/${username}.blocked`, userLine);
    fs.chmodSync(`${blockedDir}/${username}.blocked`, 0o600);
    const newLines = lines.filter(l => !l.startsWith(`${username}|`));
    fs.writeFileSync(userFile, newLines.join('\n') + '\n');
    _hysteriaSyncConfig(userFile, cfgFile);
    console.log(`[HYSTERIA-BLOCK] ${username} bloqué (password sauvegardé)`);
  } catch (e) { console.error(`[HYSTERIA-BLOCK] Erreur blockSave(${username}):`, e.message); }
}

function hysteriaBlockRestore(username, password, expires_at) {
  try {
    const userFile    = '/etc/hysteria/users.txt';
    const cfgFile     = '/etc/hysteria/config.json';
    const blockedDir  = '/etc/hysteria/blocked';
    const blockedFile = `${blockedDir}/${username}.blocked`;
    let userLine = null;
    if (fs.existsSync(blockedFile)) {
      userLine = fs.readFileSync(blockedFile, 'utf8').trim();
      fs.unlinkSync(blockedFile);
    }
    if (!userLine) {
      const expire = expires_at ? new Date(expires_at).toISOString().split('T')[0] : '2099-12-31';
      userLine = `${username}|${password}|${expire}`;
    }
    let lines = [];
    if (fs.existsSync(userFile))
      lines = fs.readFileSync(userFile, 'utf8').split('\n').filter(l => l.trim() && !l.startsWith(`${username}|`));
    lines.push(userLine);
    fs.writeFileSync(userFile, lines.join('\n') + '\n');
    fs.chmodSync(userFile, 0o600);
    _hysteriaSyncConfig(userFile, cfgFile);
    console.log(`[HYSTERIA-BLOCK] ${username} débloqué`);
  } catch (e) { console.error(`[HYSTERIA-BLOCK] Erreur blockRestore(${username}):`, e.message); }
}

function cleanupUserBandwidthFiles(username) {
  const BW_DIR   = '/var/lib/kighmu/bandwidth';
  const SENT_DIR = BW_DIR + '/sent';
  const patterns = [
    `${BW_DIR}/${username}.usage`,
    `${SENT_DIR}/${username}.sent`,
    `${BW_DIR}/udp_zivpn_${username}.usage`,
    `${BW_DIR}/udp_hysteria_${username}.usage`,
    `${SENT_DIR}/udp_zivpn_${username}.sent`,
    `${SENT_DIR}/udp_hysteria_${username}.sent`,
    `/etc/zivpn/blocked/${username}.blocked`,
    `/etc/hysteria/blocked/${username}.blocked`,
  ];
  for (const f of patterns) {
    try { fs.unlinkSync(f); console.log(`[CLEANUP] Supprimé: ${f}`); } catch {}
  }
}


// ============================================================
// V2RAY RESYNC — Réinjection automatique après réinstallation
// ============================================================
async function resyncV2rayClients() {
  const cfgPath = process.env.V2RAY_CONFIG || '/etc/v2ray/config.json';
  if (!fs.existsSync(cfgPath)) {
    console.log('[V2RAY-RESYNC] config.json absent — resync ignoré');
    return { injected: 0, skipped: 0, total: 0 };
  }
  const cfg = readJson(cfgPath);
  if (!cfg) { console.error('[V2RAY-RESYNC] Impossible de lire config.json'); return { injected:0, skipped:0, total:0 }; }
  const inb = cfg.inbounds?.find(i => i.protocol === 'vless' || i.protocol === 'vmess');
  if (!inb?.settings) { console.error('[V2RAY-RESYNC] Aucun inbound vless/vmess'); return { injected:0, skipped:0, total:0 }; }
  if (!inb.settings.clients) inb.settings.clients = [];
  let injected = 0, skipped = 0;
  try {
    const [clients] = await db.query(`
      SELECT c.username, c.uuid, c.data_limit_gb,
             COALESCE(SUM(u.upload_bytes + u.download_bytes), 0) AS used_bytes
      FROM clients c
      LEFT JOIN usage_stats u ON u.client_id = c.id
      WHERE c.tunnel_type = 'v2ray-fastdns'
        AND c.is_active   = 1
        AND c.quota_blocked = 0
        AND c.expires_at  >= NOW()
      GROUP BY c.id
    `);
    const existing = new Set(inb.settings.clients.map(c => c.id));
    for (const c of clients) {
      if (c.data_limit_gb > 0) {
        const usedGb = c.used_bytes / (1024 * 1024 * 1024);
        if (usedGb >= parseFloat(c.data_limit_gb)) {
          console.log(`[V2RAY-RESYNC] ${c.username} ignoré — quota dépassé (${usedGb.toFixed(2)}/${c.data_limit_gb} Go)`);
          skipped++; continue;
        }
      }
      if (existing.has(c.uuid)) { skipped++; continue; }
      inb.settings.clients.push({ id: c.uuid, email: c.username });
      existing.add(c.uuid);
      injected++;
      console.log(`[V2RAY-RESYNC] Réinjecté : ${c.username}`);
    }
    if (injected > 0) {
      writeJson(cfgPath, cfg);
      await restartService('v2ray');
      console.log(`[V2RAY-RESYNC] ${injected} client(s) réinjecté(s) — V2Ray redémarré`);
    } else {
      console.log(`[V2RAY-RESYNC] Aucun client à réinjecter (${skipped} déjà présents/ignorés)`);
    }
  } catch (e) { console.error('[V2RAY-RESYNC] Erreur DB:', e.message); }
  return { injected, skipped, total: injected + skipped };
}

// Endpoint admin pour déclencher manuellement la resync
app.post('/api/admin/v2ray/resync', auth(['admin']), authWriteLimiter, async (req, res) => {
  try {
    const result = await resyncV2rayClients();
    res.json({ ok: true, ...result,
      message: result.injected > 0
        ? `${result.injected} client(s) réinjecté(s) dans V2Ray`
        : `Aucun client à réinjecter (${result.skipped} déjà présents ou ignorés)`
    });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

async function addTunnel(client) {
  const { username, password, uuid, tunnel_type, expires_at } = client;
  let result = { ok: false, msg: 'tunnel_type inconnu' };
  try {
    switch (tunnel_type) {
      case 'vless':         result = xrayAdd(username, 'vless', uuid);  if (result.ok) await restartService('xray');  break;
      case 'vmess':         result = xrayAdd(username, 'vmess', uuid);  if (result.ok) await restartService('xray');  break;
      case 'trojan':        result = xrayAdd(username, 'trojan', uuid); if (result.ok) await restartService('xray');  break;
      case 'ssh-multi':
      case 'ssh-ws':
      case 'ssh-slowdns':
      case 'ssh-ssl':
      case 'ssh-udp':       result = await sshAdd(username, password, expires_at); break;
      case 'udp-zivpn': {
        result = zivpnAdd(username, password, expires_at);
        if (result.ok) {
          await restartService('zivpn');
          const readF = p => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
          const zCfg  = (() => { try { return JSON.parse(readF('/etc/zivpn/config.json')||'{}'); } catch { return {}; } })();
          const zPort = (zCfg.listen||':5667').replace(':','');
          result.config_info = { domain: readF('/etc/zivpn/domain.txt') || readF('/etc/kighmu/domain.txt') || null, obfs: zCfg.obfs || 'zivpn', port: zPort || '5667' };
        }
        break;
      }
      case 'udp-hysteria': {
        result = hysteriaAdd(username, password, expires_at);
        if (result.ok) {
          await restartService('hysteria');
          const readF = p => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
          const hCfg  = (() => { try { return JSON.parse(readF('/etc/hysteria/config.json')||'{}'); } catch { return {}; } })();
          const hPort = (hCfg.listen||':20000').replace(':','');
          result.config_info = { domain: readF('/etc/hysteria/domain.txt') || readF('/etc/kighmu/domain.txt') || null, obfs: hCfg.obfs || 'hysteria', port: hPort || '20000', port_range: `${hPort || '20000'}-50000` };
        }
        break;
      }
      case 'v2ray-fastdns': {
        result = v2rayAdd(username, uuid);
        if (result.ok) {
          await restartService('v2ray');
          const readF = p => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
          result.config_info = {
            domain: readF('/etc/kighmu/domain.txt') || null,
            v2ray_domain: readF('/.v2ray_domain') || null,
            slowdns_key_v2ray: readF('/etc/slowdns/nv4/server.pub') || readF('/etc/slowdns_v2ray/server.pub') || readF('/etc/slowdns/server.pub') || null,
            slowdns_ns_v2ray: readF('/etc/slowdns/nv4/ns.conf') || readF('/etc/slowdns_v2ray/ns.conf') || null,
          };
        }
        break;
      }
    }
  } catch (e) { result = { ok: false, msg: e.message }; }
  return result;
}

async function removeTunnel(client) {
  const { username, uuid, tunnel_type } = client;
  try {
    switch (tunnel_type) {
      case 'vless':         xrayRemove(username, 'vless', uuid);  await restartService('xray');    break;
      case 'vmess':         xrayRemove(username, 'vmess', uuid);  await restartService('xray');    break;
      case 'trojan':        xrayRemove(username, 'trojan', uuid); await restartService('xray');    break;
      case 'ssh-multi':
      case 'ssh-ws':
      case 'ssh-slowdns':
      case 'ssh-ssl':
      case 'ssh-udp':       await sshRemove(username); break;
      case 'udp-zivpn':     zivpnRemove(username); await restartService('zivpn'); break;
      case 'udp-hysteria':  hysteriaRemove(username); await restartService('hysteria'); break;
      case 'v2ray-fastdns': v2rayRemove(username, uuid); await restartService('v2ray'); break;
    }
    cleanupUserBandwidthFiles(username);
  } catch (e) { console.error(`[TUNNEL] removeTunnel error:`, e.message); }
}

async function blockTunnel(client) {
  const { username, uuid, tunnel_type } = client;
  try {
    switch (tunnel_type) {
      case 'vless':
      case 'vmess':
      case 'trojan':
      case 'v2ray-fastdns':
        if (tunnel_type === 'v2ray-fastdns') v2rayRemove(username, uuid);
        else xrayRemove(username, tunnel_type, uuid);
        await restartService(tunnel_type === 'v2ray-fastdns' ? 'v2ray' : 'xray');
        break;
      case 'ssh-multi':
      case 'ssh-ws':
      case 'ssh-slowdns':
      case 'ssh-ssl':
      case 'ssh-udp':
        await sshLock(username);
        break;
      case 'udp-zivpn':
        zivpnBlockSave(username);
        await restartService('zivpn');
        break;
      case 'udp-hysteria':
        hysteriaBlockSave(username);
        await restartService('hysteria');
        break;
    }
    console.log(`[QUOTA] Tunnel bloqué : ${username} (${tunnel_type})`);
  } catch (e) { console.error(`[QUOTA] blockTunnel error:`, e.message); }
}

async function unblockTunnel(client) {
  const { username, password, uuid, tunnel_type, expires_at } = client;
  try {
    switch (tunnel_type) {
      case 'vless':
      case 'vmess':
      case 'trojan':
        xrayAdd(username, tunnel_type, uuid); await restartService('xray'); break;
      case 'v2ray-fastdns':
        v2rayAdd(username, uuid); await restartService('v2ray'); break;
      case 'ssh-multi':
      case 'ssh-ws':
      case 'ssh-slowdns':
      case 'ssh-ssl':
      case 'ssh-udp':
        await sshUnlock(username); break;
      case 'udp-zivpn':
        zivpnBlockRestore(username, password, expires_at);
        await restartService('zivpn');
        break;
      case 'udp-hysteria':
        hysteriaBlockRestore(username, password, expires_at);
        await restartService('hysteria');
        break;
    }
    console.log(`[QUOTA] Tunnel débloqué : ${username} (${tunnel_type})`);
  } catch (e) { console.error(`[QUOTA] unblockTunnel error:`, e.message); }
}

// ============================================================
// NETTOYAGE COMPLET REVENDEUR
// ============================================================
async function cleanupReseller(resellerId) {
  try {
    const [clients] = await db.query('SELECT * FROM clients WHERE reseller_id=?', [resellerId]);
    for (const c of clients) { await removeTunnel(c); }
    await db.query('DELETE FROM usage_stats WHERE reseller_id=?',   [resellerId]);
    await db.query('DELETE FROM usage_stats WHERE client_id IN (SELECT id FROM clients WHERE reseller_id=?)', [resellerId]);
    await db.query('DELETE FROM clients WHERE reseller_id=?',       [resellerId]);
    await db.query('DELETE FROM activity_logs WHERE actor_id=? AND actor_type="reseller"', [resellerId]);
    await db.query('UPDATE resellers SET used_users=0 WHERE id=?',  [resellerId]);
    console.log(`[CLEANUP] Revendeur #${resellerId} nettoyé — ${clients.length} client(s) supprimé(s)`);
    return clients.length;
  } catch (e) {
    console.error(`[CLEANUP] Erreur nettoyage revendeur #${resellerId}:`, e.message);
    return 0;
  }
}

// ============================================================
// AUTH ROUTES
// ============================================================
app.post('/api/auth/admin/login', loginLimiter, async (req, res) => {
  try {
    const { username, password } = req.body;
    const ip = req.ip || req.connection.remoteAddress || '0.0.0.0';
    if (!username || !password) return res.status(400).json({ error: 'Identifiant et mot de passe requis' });
    if (!validateUsername(username)) return res.status(400).json({ error: 'Format de username invalide' });
    const blocked = await checkBruteForce(ip);
    if (blocked) return res.status(429).json({ error: blocked });
    const [[admin]] = await db.query('SELECT * FROM admins WHERE username=?', [username]);
    if (!admin) {
      await bcrypt.compare(password, '$2b$12$' + 'x'.repeat(53));
      await failAttempt(ip);
      return res.status(401).json({ error: 'Identifiants invalides' });
    }
    if (!(await bcrypt.compare(password, admin.password))) {
      await failAttempt(ip);
      return res.status(401).json({ error: 'Identifiants invalides' });
    }
    await clearAttempts(ip);
    await db.query('UPDATE admins SET last_login=NOW() WHERE id=?', [admin.id]);
    const token = jwt.sign({ id: admin.id, username: admin.username, role: 'admin' }, process.env.JWT_SECRET, { expiresIn: process.env.JWT_EXPIRES_IN || '2h' });
    await log('admin', admin.id, 'LOGIN', null, null, null, ip);
    res.json({ token, role: 'admin', username: admin.username });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/auth/reseller/login', loginLimiter, async (req, res) => {
  try {
    const { username, password } = req.body;
    const ip = req.ip || req.connection.remoteAddress || '0.0.0.0';
    if (!username || !password) return res.status(400).json({ error: 'Identifiant et mot de passe requis' });
    if (!validateUsername(username)) return res.status(400).json({ error: 'Format de username invalide' });
    const blocked = await checkBruteForce(ip);
    if (blocked) return res.status(429).json({ error: blocked });
    const [[r]] = await db.query('SELECT * FROM resellers WHERE username=?', [username]);
    if (!r) {
      await bcrypt.compare(password, '$2b$12$' + 'x'.repeat(53));
      await failAttempt(ip);
      return res.status(401).json({ error: 'Identifiants invalides' });
    }
    if (!(await bcrypt.compare(password, r.password))) {
      await failAttempt(ip);
      return res.status(401).json({ error: 'Identifiants invalides' });
    }
    if (!r.is_active) return res.status(403).json({ error: 'Compte désactivé' });
    if (new Date(r.expires_at) < new Date()) {
      await cleanupReseller(r.id);
      await db.query('DELETE FROM resellers WHERE id=?', [r.id]);
      return res.status(403).json({ error: 'Compte expiré — toutes vos données ont été nettoyées' });
    }
    await clearAttempts(ip);
    const token = jwt.sign({ id: r.id, username: r.username, role: 'reseller' }, process.env.JWT_SECRET, { expiresIn: process.env.JWT_EXPIRES_IN || '2h' });
    await log('reseller', r.id, 'LOGIN', null, null, null, ip);
    res.json({ token, role: 'reseller', username: r.username });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

// ============================================================
// REFRESH TOKEN
// ============================================================
app.post('/api/auth/refresh', async (req, res) => {
  try {
    const header = req.headers.authorization || '';
    const token  = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) return res.status(401).json({ error: 'Token manquant' });
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    const nowSec = Math.floor(Date.now() / 1000);
    const remaining = decoded.exp - nowSec;
    if (remaining < 0) return res.status(401).json({ error: 'Token expire' });
    const newToken = jwt.sign(
      { id: decoded.id, username: decoded.username, role: decoded.role },
      process.env.JWT_SECRET,
      { expiresIn: process.env.JWT_EXPIRES_IN || '2h' }
    );
    res.json({ token: newToken, role: decoded.role, username: decoded.username });
  } catch {
    res.status(401).json({ error: 'Token invalide' });
  }
});

// ============================================================
// ADMIN ROUTES
// ============================================================
const A = auth(['admin']);

app.get('/api/admin/resellers', A, async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT r.*,
        (SELECT COUNT(*) FROM clients WHERE reseller_id=r.id) as total_clients,
        COALESCE((SELECT SUM(u.upload_bytes+u.download_bytes) FROM usage_stats u WHERE u.reseller_id=r.id),0) as total_bytes
      FROM resellers r ORDER BY r.created_at DESC`);
    const parsed = rows.map(r => {
      let at = null;
      if (r.allowed_tunnels && typeof r.allowed_tunnels === 'string') {
        try { at = JSON.parse(r.allowed_tunnels); } catch { at = null; }
      }
      if (!Array.isArray(at) || at.length === 0) at = null;
      return { ...r, allowed_tunnels: at };
    });
    res.json(parsed);
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/admin/resellers', A, authWriteLimiter, async (req, res) => {
  try {
    const { username, password, max_users, expires_at, data_limit_gb, allowed_tunnels } = req.body;
    if (!username || !password || !expires_at) return res.status(400).json({ error: 'Champs requis manquants' });
    if (!validateUsername(username)) return res.status(400).json({ error: 'Format de username invalide' });
    const [ex] = await db.query('SELECT id FROM resellers WHERE username=?', [username]);
    if (ex.length) return res.status(409).json({ error: 'Username déjà pris' });
    let tunnelList = null;
    if (allowed_tunnels && Array.isArray(allowed_tunnels) && allowed_tunnels.length > 0) {
      const VALID = ['vless','vmess','trojan','ssh-multi','udp-zivpn','udp-hysteria','v2ray-fastdns'];
      const filtered = allowed_tunnels.filter(t => VALID.includes(t));
      tunnelList = filtered.length ? JSON.stringify(filtered) : null;
    }
    const hash = await bcrypt.hash(password, parseInt(process.env.BCRYPT_ROUNDS) || 12);
    const [r] = await db.query(
      'INSERT INTO resellers (username,password,max_users,expires_at,data_limit_gb,allowed_tunnels,created_by) VALUES (?,?,?,?,?,?,?)',
      [username, hash, max_users||10, expires_at, data_limit_gb||0, tunnelList, req.user.id]);
    await log('admin', req.user.id, 'CREATE_RESELLER', 'reseller', r.insertId, { username, data_limit_gb }, req.ip);
    res.json({ id: r.insertId, message: 'Revendeur créé' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/admin/resellers/:id', A, authWriteLimiter, async (req, res) => {
  try {
    const { username, max_users, expires_at, is_active, password, data_limit_gb, allowed_tunnels } = req.body;
    const upd = {};
    if (username !== undefined && username.trim()) {
      const [[ex]] = await db.query('SELECT id FROM resellers WHERE username=? AND id!=?', [username.trim(), req.params.id]);
      if (ex) return res.status(409).json({ error: 'Ce username est déjà utilisé' });
      upd.username = username.trim();
    }
    if (max_users      !== undefined) upd.max_users      = max_users;
    if (expires_at     !== undefined) upd.expires_at     = expires_at;
    if (is_active      !== undefined) upd.is_active      = is_active;
    if (data_limit_gb  !== undefined) {
      upd.data_limit_gb = data_limit_gb;
      // Si la limite est augmentée ou supprimée (0=illimité), débloquer le revendeur et ses clients
      const [[rCur]] = await db.query('SELECT quota_blocked, data_limit_gb FROM resellers WHERE id=?', [req.params.id]);
      if (rCur && rCur.quota_blocked && (data_limit_gb === 0 || parseFloat(data_limit_gb) > parseFloat(rCur.data_limit_gb))) {
        upd.quota_blocked = 0;
        // Débloquer tous les clients quota_blocked du revendeur
        const [blockedClients] = await db.query('SELECT * FROM clients WHERE reseller_id=? AND quota_blocked=1', [req.params.id]);
        for (const c of blockedClients) {
          await unblockTunnel(c);
          await db.query('UPDATE clients SET quota_blocked=0, is_active=1 WHERE id=?', [c.id]);
        }
        console.log(`[QUOTA] Revendeur #${req.params.id} débloqué par admin (${blockedClients.length} client(s) restauré(s))`);
        await log('admin', req.user.id, 'QUOTA_UNBLOCK_RESELLER', 'reseller', req.params.id, { clients_unblocked: blockedClients.length, new_limit_gb: data_limit_gb }, req.ip);
      }
    }
    if (allowed_tunnels !== undefined) {
      if (Array.isArray(allowed_tunnels) && allowed_tunnels.length > 0) {
        const VALID = ['vless','vmess','trojan','ssh-multi','udp-zivpn','udp-hysteria','v2ray-fastdns'];
        const filtered = allowed_tunnels.filter(t => VALID.includes(t));
        upd.allowed_tunnels = filtered.length ? JSON.stringify(filtered) : null;
      } else { upd.allowed_tunnels = null; }
    }
    if (password) upd.password = await bcrypt.hash(password, parseInt(process.env.BCRYPT_ROUNDS) || 12);
    if (!Object.keys(upd).length) return res.status(400).json({ error: 'Aucun champ à modifier' });
    const sets = Object.keys(upd).map(k => `${k}=?`).join(',');
    await db.query(`UPDATE resellers SET ${sets} WHERE id=?`, [...Object.values(upd), req.params.id]);
    await log('admin', req.user.id, 'UPDATE_RESELLER', 'reseller', req.params.id, upd, req.ip);
    res.json({ message: 'Revendeur mis à jour' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.delete('/api/admin/resellers/:id', A, authWriteLimiter, async (req, res) => {
  try {
    const [[r]] = await db.query('SELECT username FROM resellers WHERE id=?', [req.params.id]);
    if (!r) return res.status(404).json({ error: 'Revendeur introuvable' });
    const cleaned = await cleanupReseller(req.params.id);
    await db.query('DELETE FROM resellers WHERE id=?', [req.params.id]);
    await log('admin', req.user.id, 'DELETE_RESELLER', 'reseller', req.params.id, { username: r.username, clients_cleaned: cleaned }, req.ip);
    res.json({ message: `Revendeur supprimé + ${cleaned} client(s) nettoyé(s)` });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/admin/resellers/:id/clean', A, authWriteLimiter, async (req, res) => {
  try {
    const cleaned = await cleanupReseller(req.params.id);
    await log('admin', req.user.id, 'CLEAN_RESELLER', 'reseller', req.params.id, { clients_cleaned: cleaned }, req.ip);
    res.json({ message: `${cleaned} client(s) nettoyé(s)` });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/admin/clients', A, async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT c.*, r.username as reseller_name,
        COALESCE(SUM(u.upload_bytes),0) as total_upload,
        COALESCE(SUM(u.download_bytes),0) as total_download
      FROM clients c
      LEFT JOIN resellers r ON c.reseller_id=r.id
      LEFT JOIN usage_stats u ON u.client_id=c.id
      GROUP BY c.id ORDER BY c.created_at DESC`);
    res.json(rows);
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/admin/clients', A, authWriteLimiter, async (req, res) => {
  try {
    const { username, password, tunnel_type, expires_at, note, reseller_id, data_limit_gb } = req.body;
    if (!username || !tunnel_type || !expires_at)
      return res.status(400).json({ error: 'username, tunnel_type et expires_at sont requis' });
    if (!validateUsername(username)) return res.status(400).json({ error: 'Format de username invalide (3-32 car., lettres/chiffres/tirets)' });
    const [ex] = await db.query('SELECT id FROM clients WHERE username=?', [username]);
    if (ex.length) return res.status(409).json({ error: 'Username déjà utilisé' });
    if (reseller_id) {
      const [[r]] = await db.query('SELECT max_users, used_users FROM resellers WHERE id=?', [reseller_id]);
      if (!r) return res.status(404).json({ error: 'Revendeur introuvable' });
      if (r.used_users >= r.max_users) return res.status(403).json({ error: `Limite revendeur atteinte (${r.max_users})` });
    }
    const uuid = uuidv4();
    const pass = password || crypto.randomBytes(12).toString('base64url').slice(0, 16);
    const [ins] = await db.query(
      'INSERT INTO clients (username,password,uuid,reseller_id,tunnel_type,expires_at,note,data_limit_gb) VALUES (?,?,?,?,?,?,?,?)',
      [username, pass, uuid, reseller_id||null, tunnel_type, expires_at, note||null, data_limit_gb||0]);
    if (reseller_id) await db.query('UPDATE resellers SET used_users=used_users+1 WHERE id=?', [reseller_id]);
    const tunnelResult = await addTunnel({ username, password: pass, uuid, tunnel_type, expires_at });
    await log('admin', req.user.id, 'CREATE_CLIENT', 'client', ins.insertId, { username, tunnel_type, data_limit_gb }, req.ip);
    const readF = p => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
    const vpsInfo = {
      domain:           getVpsDomain() || null,
      xray_domain:      readF('/etc/xray/domain') || readF('/tmp/.xray_domain') || null,
      v2ray_domain:     readF('/.v2ray_domain') || null,
      slowdns_key:      readF('/etc/slowdns/server.pub')        || null,
      slowdns_ns:       readF('/etc/slowdns/ns.conf')           || null,
      slowdns_key_v2ray:readF('/etc/slowdns/nv4/server.pub')   || readF('/etc/slowdns_v2ray/server.pub')|| readF('/etc/slowdns/server.pub')|| null,
      slowdns_ns_v2ray: readF('/etc/slowdns/nv4/ns.conf')      || readF('/etc/slowdns_v2ray/ns.conf')   || null,
    };
    let hostIp = null;
    try { const nets = await si.networkInterfaces(); const eth=nets.find(n=>!n.internal&&n.ip4); hostIp=eth?.ip4||null; } catch {}
    vpsInfo.host_ip = hostIp;
    res.json({ id: ins.insertId, username, password: pass, uuid, tunnel_type, expires_at, data_limit_gb: data_limit_gb||0, tunnelResult, vpsInfo });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/admin/clients/:id', A, authWriteLimiter, async (req, res) => {
  try {
    const { username, password, uuid, expires_at, note, is_active, data_limit_gb } = req.body;
    const [[c]] = await db.query('SELECT * FROM clients WHERE id=?', [req.params.id]);
    if (!c) return res.status(404).json({ error: 'Client introuvable' });
    const upd = {};
    let tunnelChanged = false;
    if (username !== undefined && username.trim() && username.trim() !== c.username) {
      const [[ex]] = await db.query('SELECT id FROM clients WHERE username=? AND id!=?', [username.trim(), c.id]);
      if (ex) return res.status(409).json({ error: 'Ce username est déjà utilisé' });
      upd.username = username.trim();
      tunnelChanged = true;
    }
    if (password !== undefined && password.trim()) { upd.password = password.trim(); tunnelChanged = true; }
    if (uuid !== undefined && uuid.trim() && uuid.trim() !== c.uuid) { upd.uuid = uuid.trim(); tunnelChanged = true; }
    if (expires_at !== undefined) {
      upd.expires_at = expires_at;
      tunnelChanged = true;
      if (new Date(expires_at) > new Date() && !c.is_active) upd.is_active = 1;
    }
    if (note          !== undefined) upd.note          = note;
    if (is_active     !== undefined) { upd.is_active = is_active; tunnelChanged = true; }
    if (data_limit_gb !== undefined) upd.data_limit_gb = data_limit_gb;
    if (data_limit_gb !== undefined && c.quota_blocked) {
      upd.quota_blocked = 0;
      const toUnblock = { ...c, ...upd };
      await unblockTunnel(toUnblock);
    }
    if (!Object.keys(upd).length) return res.status(400).json({ error: 'Aucun champ à modifier' });
    if (tunnelChanged) {
      const updated = { ...c, ...upd };
      const active = updated.is_active && (!updated.expires_at || new Date(updated.expires_at) > new Date());
      if (active) {
        await removeTunnel(c);
        await addTunnel(updated);
      } else {
        await removeTunnel(c);
      }
    }
    const sets = Object.keys(upd).map(k => `${k}=?`).join(',');
    await db.query(`UPDATE clients SET ${sets} WHERE id=?`, [...Object.values(upd), req.params.id]);
    await log('admin', req.user.id, 'UPDATE_CLIENT', 'client', req.params.id, { fields: Object.keys(upd), tunnelChanged }, req.ip);
    res.json({ message: 'Client mis à jour', tunnelChanged });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.delete('/api/admin/clients/:id', A, authWriteLimiter, async (req, res) => {
  try {
    const [[c]] = await db.query('SELECT * FROM clients WHERE id=?', [req.params.id]);
    if (!c) return res.status(404).json({ error: 'Client introuvable' });
    await removeTunnel(c);
    if (c.reseller_id) await db.query('UPDATE resellers SET used_users=used_users-1 WHERE id=? AND used_users>0', [c.reseller_id]);
    await db.query('DELETE FROM usage_stats WHERE client_id=?', [req.params.id]);
    await db.query('DELETE FROM clients WHERE id=?', [req.params.id]);
    await log('admin', req.user.id, 'DELETE_CLIENT', 'client', req.params.id, null, req.ip);
    res.json({ message: 'Client supprimé' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/admin/stats', A, async (req, res) => {
  try {
    const dNow = new Date();
    const [[mt]] = await db.query('SELECT total_upload, total_download FROM monthly_totals WHERE year=? AND month=?', [dNow.getFullYear(), dNow.getMonth()+1]);
    const usage = { total_upload: (mt && mt.total_upload) || 0, total_download: (mt && mt.total_download) || 0 };
    const [[counts]] = await db.query(`SELECT
      (SELECT COUNT(*) FROM resellers)              as total_resellers,
      (SELECT COUNT(*) FROM clients)                as total_clients,
      (SELECT COUNT(*) FROM clients WHERE is_active=1) as active_clients`);
    const [resellerStats] = await db.query(`
      SELECT r.id, r.username, r.max_users, r.used_users, r.data_limit_gb, r.expires_at, r.is_active,
        COALESCE(SUM(u.upload_bytes+u.download_bytes),0) as total_bytes
      FROM resellers r LEFT JOIN usage_stats u ON u.reseller_id=r.id GROUP BY r.id`);
    const [cpu, mem, disk] = await Promise.all([si.currentLoad(), si.mem(), si.fsSize()]);

    // Stats mensuelles : consommation depuis le début du mois courant
    const monthStart = new Date(dNow.getFullYear(), dNow.getMonth(), 1).toISOString().slice(0,10);
    const [[mtd]] = await db.query('SELECT total_upload, total_download FROM monthly_totals WHERE year=? AND month=?', [dNow.getFullYear(), dNow.getMonth()+1]);
    const monthly = {
      month_upload:   (mtd && mtd.total_upload)   || 0,
      month_download: (mtd && mtd.total_download) || 0
    };
    // Stats par revendeur pour le mois courant
    const [monthlyResellers] = await db.query(`
      SELECT r.username,
        COALESCE(SUM(u.upload_bytes),0) as month_upload,
        COALESCE(SUM(u.download_bytes),0) as month_download
      FROM resellers r
      LEFT JOIN usage_stats u ON u.reseller_id=r.id AND u.recorded_at >= ?
      GROUP BY r.id ORDER BY (month_upload+month_download) DESC`, [monthStart]);

    res.json({
      global: { ...usage, ...counts },
      monthly: { ...monthly, month_start: monthStart, resellers: monthlyResellers },
      resellers: resellerStats,
      system: {
        cpu_usage:  cpu.currentLoad.toFixed(1),
        ram_total:  mem.total,
        ram_used:   mem.used,
        ram_free:   mem.free,
        disk: disk[0] ? { total: disk[0].size, used: disk[0].used, free: disk[0].available } : null
      }
    });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

// Reset mensuel manuel
app.post('/api/admin/stats/reset-monthly', A, authWriteLimiter, async (req, res) => {
  try {
    const d = new Date();
    await db.query(
      'INSERT INTO monthly_totals (year,month,total_upload,total_download) VALUES (?,?,0,0) ON DUPLICATE KEY UPDATE total_upload=0, total_download=0',
      [d.getFullYear(), d.getMonth()+1]
    );
    await log('admin', req.user.id, 'RESET_MONTHLY_STATS', 'system', null, {}, req.ip);
    res.json({ ok: true, message: 'Total mensuel réinitialisé (les stats individuelles sont conservées)' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/admin/logs', A, async (req, res) => {
  try {
    const [rows] = await db.query('SELECT * FROM activity_logs ORDER BY created_at DESC LIMIT 200');
    res.json(rows);
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

// ============================================================
// RESELLER ROUTES
// ============================================================
const R = auth(['reseller']);

app.get('/api/reseller/me', R, async (req, res) => {
  try {
    const [[r]] = await db.query(`
      SELECT r.id, r.username, r.max_users, r.used_users, r.data_limit_gb, r.allowed_tunnels, r.expires_at, r.is_active,
        COALESCE(SUM(u.upload_bytes+u.download_bytes),0) as total_bytes
      FROM resellers r LEFT JOIN usage_stats u ON u.reseller_id=r.id
      WHERE r.id=? GROUP BY r.id`, [req.user.id]);
    if (r) {
      if (r.allowed_tunnels && typeof r.allowed_tunnels === 'string') {
        try { r.allowed_tunnels = JSON.parse(r.allowed_tunnels); } catch { r.allowed_tunnels = null; }
      }
      if (!Array.isArray(r.allowed_tunnels) || r.allowed_tunnels.length === 0) r.allowed_tunnels = null;
    }
    res.json(r);
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/reseller/clients', R, async (req, res) => {
  try {
    const [rows] = await db.query(`
      SELECT c.*,
        COALESCE(SUM(u.upload_bytes),0) as total_upload,
        COALESCE(SUM(u.download_bytes),0) as total_download
      FROM clients c LEFT JOIN usage_stats u ON u.client_id=c.id
      WHERE c.reseller_id=? GROUP BY c.id ORDER BY c.created_at DESC`, [req.user.id]);
    res.json(rows);
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/reseller/clients', R, authWriteLimiter, async (req, res) => {
  try {
    const { username, password, tunnel_type, expires_at, note, data_limit_gb } = req.body;
    if (!username || !tunnel_type || !expires_at) return res.status(400).json({ error: 'Champs requis manquants' });
    if (!validateUsername(username)) return res.status(400).json({ error: 'Format de username invalide' });
    const [[r]] = await db.query('SELECT * FROM resellers WHERE id=?', [req.user.id]);
    if (r.used_users >= r.max_users) return res.status(403).json({ error: `Limite atteinte (${r.max_users} max)` });
    // Bloquer la création si quota data dépassé
    if (r.quota_blocked) return res.status(403).json({ error: 'Quota de données dépassé — création de clients suspendue. Contactez l\'administrateur.' });
    if (r.allowed_tunnels) {
      let allowed;
      try { allowed = JSON.parse(r.allowed_tunnels); } catch { allowed = []; }
      if (!Array.isArray(allowed) || allowed.length === 0) allowed = null;
      if (allowed) {
        const SSH_VARIANTS = ['ssh-multi','ssh-ws','ssh-slowdns','ssh-ssl','ssh-udp'];
        const sshAllowed = allowed.includes('ssh-multi');
        const isSSH = SSH_VARIANTS.includes(tunnel_type);
        if (!(allowed.includes(tunnel_type) || (isSSH && sshAllowed))) {
          return res.status(403).json({ error: `Tunnel "${tunnel_type}" non autorisé pour votre compte` });
        }
      }
    }
    const [ex] = await db.query('SELECT id FROM clients WHERE username=?', [username]);
    if (ex.length) return res.status(409).json({ error: 'Username déjà utilisé' });
    const uuid = uuidv4();
    const pass = password || crypto.randomBytes(12).toString('base64url').slice(0, 16);
    const [ins] = await db.query(
      'INSERT INTO clients (username,password,uuid,reseller_id,tunnel_type,expires_at,note,data_limit_gb) VALUES (?,?,?,?,?,?,?,?)',
      [username, pass, uuid, req.user.id, tunnel_type, expires_at, note||null, data_limit_gb||0]);
    await db.query('UPDATE resellers SET used_users=used_users+1 WHERE id=?', [req.user.id]);
    const tunnelResult = await addTunnel({ username, password: pass, uuid, tunnel_type, expires_at });
    await log('reseller', req.user.id, 'CREATE_CLIENT', 'client', ins.insertId, { username, tunnel_type }, req.ip);
    // Même vpsInfo que la route admin — nécessaire pour afficher le domaine côté revendeur
    const readF = p => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
    const vpsInfo = {
      domain:           getVpsDomain() || null,
      xray_domain:      readF('/etc/xray/domain') || readF('/tmp/.xray_domain') || null,
      v2ray_domain:     readF('/.v2ray_domain') || null,
      slowdns_key:      readF('/etc/slowdns/server.pub')        || null,
      slowdns_ns:       readF('/etc/slowdns/ns.conf')           || null,
      slowdns_key_v2ray:readF('/etc/slowdns/nv4/server.pub')   || readF('/etc/slowdns_v2ray/server.pub')|| readF('/etc/slowdns/server.pub')|| null,
      slowdns_ns_v2ray: readF('/etc/slowdns/nv4/ns.conf')      || readF('/etc/slowdns_v2ray/ns.conf')   || null,
    };
    let hostIp = null;
    try { const nets = await si.networkInterfaces(); const eth=nets.find(n=>!n.internal&&n.ip4); hostIp=eth?.ip4||null; } catch {}
    vpsInfo.host_ip = hostIp;
    res.json({ id: ins.insertId, username, password: pass, uuid, tunnel_type, expires_at, data_limit_gb: data_limit_gb||0, tunnelResult, vpsInfo });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/reseller/clients/:id', R, authWriteLimiter, async (req, res) => {
  try {
    const [[c]] = await db.query('SELECT * FROM clients WHERE id=? AND reseller_id=?', [req.params.id, req.user.id]);
    if (!c) return res.status(404).json({ error: 'Client introuvable' });
    const { expires_at, note, is_active, data_limit_gb } = req.body;
    const upd = {};
    let tunnelChanged = false;
    if (expires_at !== undefined) {
      upd.expires_at = expires_at;
      tunnelChanged = true;
      if (new Date(expires_at) > new Date() && !c.is_active) upd.is_active = 1;
    }
    if (note          !== undefined) upd.note          = note;
    if (is_active     !== undefined) { upd.is_active = is_active; tunnelChanged = true; }
    if (data_limit_gb !== undefined) upd.data_limit_gb = data_limit_gb;
    if (data_limit_gb !== undefined && c.quota_blocked) {
      upd.quota_blocked = 0;
      await unblockTunnel(c);
    }
    if (tunnelChanged) {
      const updated = { ...c, ...upd };
      const active = updated.is_active && (!updated.expires_at || new Date(updated.expires_at) > new Date());
      if (active) {
        await removeTunnel(c);
        await addTunnel(updated);
      } else {
        await removeTunnel(c);
      }
    }
    const sets = Object.keys(upd).map(k => `${k}=?`).join(',');
    if (sets) await db.query(`UPDATE clients SET ${sets} WHERE id=?`, [...Object.values(upd), req.params.id]);
    await log('reseller', req.user.id, 'UPDATE_CLIENT', 'client', req.params.id, upd, req.ip);
    res.json({ message: 'Client mis à jour' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.delete('/api/reseller/clients/:id', R, authWriteLimiter, async (req, res) => {
  try {
    const [[c]] = await db.query('SELECT * FROM clients WHERE id=? AND reseller_id=?', [req.params.id, req.user.id]);
    if (!c) return res.status(404).json({ error: 'Client introuvable' });
    await removeTunnel(c);
    await db.query('DELETE FROM usage_stats WHERE client_id=?', [req.params.id]);
    await db.query('DELETE FROM clients WHERE id=?', [req.params.id]);
    await db.query('UPDATE resellers SET used_users=used_users-1 WHERE id=? AND used_users>0', [req.user.id]);
    await log('reseller', req.user.id, 'DELETE_CLIENT', 'client', req.params.id, null, req.ip);
    res.json({ message: 'Client supprimé' });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

// ============================================================
// HELPER : lecture domaine VPS (multi-sources dont ~/.kighmu_info)
// ============================================================
function getVpsDomain() {
  const readFile = (p) => { try { return require('fs').readFileSync(p,'utf8').trim(); } catch { return null; } };
  const parseKV  = (p, key) => {
    try {
      const txt = require('fs').readFileSync(p, 'utf8');
      const m = txt.match(new RegExp('^' + key + '=(.+)$', 'm'));
      return m && m[1].trim() ? m[1].trim() : null;
    } catch { return null; }
  };

  // 1. /etc/kighmu/domain.txt — mais seulement si c'est un vrai domaine (pas une IP pure)
  const domainTxt = readFile('/etc/kighmu/domain.txt');
  if (domainTxt && !/^\d+\.\d+\.\d+\.\d+$/.test(domainTxt)) return domainTxt;

  // 2. ~/.kighmu_info → DOMAIN= (écrit par menu1.sh et install-1.sh corrigé)
  const fromKighmuInfo = parseKV(`${process.env.HOME || '/root'}/.kighmu_info`, 'DOMAIN');
  if (fromKighmuInfo && !/^\d+\.\d+\.\d+\.\d+$/.test(fromKighmuInfo)) return fromKighmuInfo;

  // 3. .install_info (écrit par install-1.sh)
  const fromInstallInfo = parseKV('/opt/kighmu-panel/.install_info', 'DOMAIN');
  if (fromInstallInfo && !/^\d+\.\d+\.\d+\.\d+$/.test(fromInstallInfo)) return fromInstallInfo;

  // 4. /etc/xray/domain ou /tmp/.xray_domain
  const xrayDomain = readFile('/etc/xray/domain') || readFile('/tmp/.xray_domain');
  if (xrayDomain && !/^\d+\.\d+\.\d+\.\d+$/.test(xrayDomain)) return xrayDomain;

  // 5. Fallback IP (si aucun domaine trouvé, retourner ce qu'on a)
  return fromKighmuInfo || fromInstallInfo || domainTxt || xrayDomain || null;
}

// ============================================================
// VPS INFO ROUTES
// ============================================================
app.get('/api/admin/vps-info', A, authWriteLimiter, async (req, res) => {
  try {
    const readFile = (p) => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
    const domain = getVpsDomain();
    let hostIp = null;
    try { const nets = await si.networkInterfaces(); const eth = nets.find(n => !n.internal && n.ip4); hostIp = eth?.ip4 || null; } catch {}
    const slowdnsKey = readFile('/etc/slowdns/server.pub')       || null;
    const slowdnsNs  = readFile('/etc/slowdns/ns.conf')          || null;
    const slowdnsKeyV2 = readFile('/etc/slowdns/nv4/server.pub') || readFile('/etc/slowdns_v2ray/server.pub') || readFile('/etc/slowdns/server.pub') || null;
    const slowdnsNsV2  = readFile('/etc/slowdns/nv4/ns.conf')   || readFile('/etc/slowdns_v2ray/ns.conf')    || null;
    const xrayDomain = readFile('/etc/xray/domain') || readFile('/tmp/.xray_domain') || domain;
    const v2rayDomain = readFile('/.v2ray_domain') || domain;
    let hysteriaPort = '20000';
    try { const hCfg = JSON.parse(readFile('/etc/hysteria/config.json') || '{}'); hysteriaPort = (hCfg.listen || ':20000').replace(':','') || '20000'; } catch {}
    let zivpnPort = '5667';
    try { const zCfg = JSON.parse(readFile('/etc/zivpn/config.json') || '{}'); zivpnPort = (zCfg.listen || ':5667').replace(':','') || '5667'; } catch {}
    res.json({ domain, xray_domain: xrayDomain, v2ray_domain: v2rayDomain, host_ip: hostIp, slowdns_key: slowdnsKey, slowdns_ns: slowdnsNs, slowdns_key_v2ray: slowdnsKeyV2, slowdns_ns_v2ray: slowdnsNsV2, hysteria_port: hysteriaPort, hysteria_port_range: `${hysteriaPort}-50000`, zivpn_port: zivpnPort, ssh_ports: { ws: '80', ssl: '444', proxy_ws: '9090', udp: '1-65535', slowdns: '5300', dropbear: '2222', badvpn: '7200,7300' } });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/reseller/vps-info', R, async (req, res) => {
  const readFile = (p) => { try { return fs.readFileSync(p,'utf8').trim(); } catch { return null; } };
  const domain = getVpsDomain();
  let hostIp = null;
  try { const nets = await si.networkInterfaces(); const eth = nets.find(n=>!n.internal&&n.ip4); hostIp=eth?.ip4||null; } catch {}
  const slowdnsKey = readFile('/etc/slowdns/server.pub')       || null;
  const slowdnsNs  = readFile('/etc/slowdns/ns.conf')          || null;
  const slowdnsKeyV2 = readFile('/etc/slowdns/nv4/server.pub') || readFile('/etc/slowdns_v2ray/server.pub') || readFile('/etc/slowdns/server.pub') || null;
  const slowdnsNsV2  = readFile('/etc/slowdns/nv4/ns.conf')   || readFile('/etc/slowdns_v2ray/ns.conf')    || null;
  let hysteriaPort='20000'; try { const h=JSON.parse(readFile('/etc/hysteria/config.json')||'{}'); hysteriaPort=(h.listen||':20000').replace(':','')||'20000'; } catch {}
  let zivpnPort='5667'; try { const z=JSON.parse(readFile('/etc/zivpn/config.json')||'{}'); zivpnPort=(z.listen||':5667').replace(':','')||'5667'; } catch {}
  res.json({ domain, host_ip: hostIp, slowdns_key: slowdnsKey, slowdns_ns: slowdnsNs, slowdns_key_v2ray: slowdnsKeyV2, slowdns_ns_v2ray: slowdnsNsV2, hysteria_port: hysteriaPort, hysteria_port_range: `${hysteriaPort}-50000`, zivpn_port: zivpnPort, xray_domain: readFile('/etc/xray/domain')||readFile('/tmp/.xray_domain')||domain, v2ray_domain: readFile('/.v2ray_domain')||domain, ssh_ports: { ws:'80', ssl:'444', proxy_ws:'9090', udp:'1-65535', slowdns:'5300' } });
});

// ============================================================
// ROUTE RAPPORT TRAFIC
// ============================================================
app.post('/api/report/traffic', writeLimiter, async (req, res) => {
  try {
    const secret = req.headers['x-report-secret'] || req.body.secret;
    if (secret !== (REPORT_SECRET))
      return res.status(403).json({ error: 'Secret invalide' });
    const { stats } = req.body;
    if (!Array.isArray(stats)) return res.status(400).json({ error: 'Format: { stats:[{username,upload_bytes,download_bytes}] }' });
    let updated = 0, totalUp = 0, totalDown = 0;
    for (const s of stats) {
      if (!s.username) continue;
      const up   = parseInt(s.upload_bytes)   || 0;
      const down = parseInt(s.download_bytes) || 0;
      if (up === 0 && down === 0) continue;
      totalUp += up; totalDown += down;
      const [[c]] = await db.query('SELECT id, reseller_id FROM clients WHERE username=?', [s.username]);
      if (!c) continue;
      const [[ex]] = await db.query('SELECT id FROM usage_stats WHERE client_id=? ORDER BY recorded_at DESC LIMIT 1', [c.id]).catch(() => [[null]]);
      if (ex) {
        await db.query('UPDATE usage_stats SET upload_bytes=upload_bytes+?, download_bytes=download_bytes+?, recorded_at=NOW() WHERE id=?', [up, down, ex.id]);
      } else {
        await db.query('INSERT INTO usage_stats (client_id, reseller_id, upload_bytes, download_bytes) VALUES (?,?,?,?)', [c.id, c.reseller_id || null, up, down]);
      }
      updated++;
    }
    if (totalUp > 0 || totalDown > 0) {
      const d = new Date();
      await db.query(
        'INSERT INTO monthly_totals (year,month,total_upload,total_download) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE total_upload=total_upload+VALUES(total_upload), total_download=total_download+VALUES(total_download)',
        [d.getFullYear(), d.getMonth()+1, totalUp, totalDown]
      );
    }
    res.json({ ok: true, updated });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/report/traffic/set', writeLimiter, async (req, res) => {
  try {
    const secret = req.headers['x-report-secret'] || req.body.secret;
    if (secret !== (REPORT_SECRET))
      return res.status(403).json({ error: 'Secret invalide' });
    const { username, upload_bytes, download_bytes } = req.body;
    if (!username) return res.status(400).json({ error: 'username requis' });
    const up   = parseInt(upload_bytes)   || 0;
    const down = parseInt(download_bytes) || 0;
    const [[c]] = await db.query('SELECT id, reseller_id FROM clients WHERE username=?', [username]);
    if (!c) return res.status(404).json({ error: 'Client introuvable' });
    const [[ex]] = await db.query('SELECT id FROM usage_stats WHERE client_id=? LIMIT 1', [c.id]).catch(() => [[null]]);
    if (ex) {
      await db.query('UPDATE usage_stats SET upload_bytes=?, download_bytes=?, recorded_at=NOW() WHERE id=?', [up, down, ex.id]);
    } else {
      await db.query('INSERT INTO usage_stats (client_id, reseller_id, upload_bytes, download_bytes) VALUES (?,?,?,?)', [c.id, c.reseller_id || null, up, down]);
    }
    if (up > 0 || down > 0) {
      const d = new Date();
      await db.query(
        'INSERT INTO monthly_totals (year,month,total_upload,total_download) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE total_upload=total_upload+VALUES(total_upload), total_download=total_download+VALUES(total_download)',
        [d.getFullYear(), d.getMonth()+1, up, down]
      );
    }
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: 'Erreur serveur' }); }
});

// ============================================================
// SPA ROUTING — avec injection nonce CSP
// ============================================================
const htmlCache = {};
function serveHTML(filePath, req, res) {
  try {
    if (!fs.existsSync(filePath)) return res.status(404).send('Fichier introuvable');
    if (!htmlCache[filePath]) htmlCache[filePath] = fs.readFileSync(filePath, 'utf8');
    let html = htmlCache[filePath];
    if (req.nonce) html = html.replace(/__NONCE__/g, req.nonce);
    res.type('html').send(html);
  } catch (e) {
    res.status(500).send('Erreur serveur');
  }
}
app.get('/admin*',    (req, res) => serveHTML(path.join(FRONTEND, 'admin/index.html'), req, res));
app.get('/reseller*', (req, res) => serveHTML(path.join(FRONTEND, 'reseller/index.html'), req, res));
app.get('*',          (req, res) => serveHTML(path.join(FRONTEND, 'index.html'), req, res));

app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(500).json({ error: 'Erreur interne du serveur' });
});

process.on('uncaughtException',  e => console.error('[UNCAUGHT]', e.message));
process.on('unhandledRejection', e => console.error('[UNHANDLED]', e));

// ============================================================
// CRON JOBS
// ============================================================
function startCron() {
  // ── Health check DB toutes les 30s (reconnexion auto si MySQL crash) ──
  setInterval(async () => {
    if (db) await dbHealthCheck();
  }, 30000);

  // ── Sync regles nftables SSH toutes les 10 min (recuperation apres reboot) ──
  setInterval(async () => {
    if (db) await syncAllSshRules();
  }, 600000);

  cron.schedule('*/5 * * * *', async () => { // toutes les 5 min pour blocage rapide
    const ok = db ? await dbHealthCheck() : false;
    if (!ok) return;
    try {
      const [expiredResellers] = await db.query('SELECT id, username FROM resellers WHERE expires_at < NOW()');
      for (const r of expiredResellers) {
        console.log(`[CRON] Revendeur expiré: ${r.username} (#${r.id}) — nettoyage...`);
        await cleanupReseller(r.id);
        await db.query('DELETE FROM resellers WHERE id=?', [r.id]);
        await db.query("INSERT INTO activity_logs (actor_type,actor_id,action,target_type,target_id,details) VALUES ('admin',0,'AUTO_EXPIRE_RESELLER','reseller',?,?)", [r.id, JSON.stringify({username:r.username,reason:'Expiration automatique'})]);
      }
      if (expiredResellers.length) console.log(`[CRON] ${expiredResellers.length} revendeur(s) expiré(s) supprimés`);

      const [expClients] = await db.query('SELECT * FROM clients WHERE expires_at < NOW() AND is_active=1');
      for (const c of expClients) {
        await removeTunnel(c);
        await db.query('UPDATE clients SET is_active=0 WHERE id=?', [c.id]);
      }
      if (expClients.length) console.log(`[CRON] ${expClients.length} client(s) expiré(s) désactivés`);

      const [clientsWithQuota] = await db.query(`
        SELECT c.id, c.username, c.tunnel_type, c.uuid, c.password, c.expires_at,
               c.data_limit_gb, c.quota_blocked, c.is_active,
               COALESCE(SUM(u.upload_bytes+u.download_bytes),0) as total_bytes
        FROM clients c LEFT JOIN usage_stats u ON u.client_id=c.id
        WHERE c.data_limit_gb>0 AND c.is_active=1 GROUP BY c.id`);
      for (const c of clientsWithQuota) {
        const usedGb  = c.total_bytes / (1024*1024*1024);
        const limitGb = parseFloat(c.data_limit_gb);
        if (usedGb >= limitGb && !c.quota_blocked) {
          await blockTunnel(c);
          await db.query('UPDATE clients SET quota_blocked=1, is_active=0 WHERE id=?', [c.id]);
          console.log(`[CRON] Quota dépassé → bloqué: ${c.username} (${usedGb.toFixed(2)}GB/${limitGb}GB)`);
        }
      }

      // ── Quota revendeur ─────────────────────────────────────────────────
      // Requête : revendeurs dont le quota est dépassé ET pas encore bloqués
      const [resellersWithQuota] = await db.query(`
        SELECT r.id, r.username, r.data_limit_gb,
               COALESCE(SUM(u.upload_bytes+u.download_bytes),0) as total_bytes
        FROM resellers r LEFT JOIN usage_stats u ON u.reseller_id=r.id
        WHERE r.data_limit_gb>0 AND r.is_active=1 AND r.quota_blocked=0 GROUP BY r.id
        HAVING total_bytes >= (r.data_limit_gb * 1073741824)`);
      for (const r of resellersWithQuota) {
        const usedGb  = r.total_bytes / (1024*1024*1024);
        const limitGb = parseFloat(r.data_limit_gb);
        console.log(`[CRON] Quota revendeur dépassé: ${r.username} (${usedGb.toFixed(2)}GB/${limitGb}GB) — blocage immédiat...`);

        // 1. Bloquer TOUS les clients actifs du revendeur (retire de Xray/SSH/etc.)
        const [rClients] = await db.query('SELECT * FROM clients WHERE reseller_id=? AND is_active=1', [r.id]);
        for (const c of rClients) {
          await blockTunnel(c);
          await db.query('UPDATE clients SET quota_blocked=1, is_active=0 WHERE id=?', [c.id]);
        }

        // 2. Marquer le revendeur lui-même comme quota_blocked (bloque la création de nouveaux clients)
        await db.query('UPDATE resellers SET quota_blocked=1 WHERE id=?', [r.id]);

        await log('admin', 0, 'QUOTA_BLOCK_RESELLER', 'reseller', r.id, {
          username: r.username,
          used_gb: usedGb.toFixed(3),
          limit_gb: limitGb,
          clients_blocked: rClients.length
        }, null);
        console.log(`[CRON] Revendeur ${r.username} bloqué — ${rClients.length} client(s) coupé(s)`);
      }
    } catch (e) { console.error('[CRON] erreur:', e.message); }
  });

  cron.schedule('0 0 * * *', async () => {
    if (!db) return;
    try { await db.query("DELETE FROM login_attempts WHERE last_attempt < DATE_SUB(NOW(), INTERVAL 1 DAY)"); } catch {}
  });

  // Nouveau mois : un nouveau total mensuel commence à 0 (les anciens restent archivés)
  cron.schedule('5 0 1 * *', async () => {
    if (!db) return;
    try {
      const d = new Date();
      await db.query(
        'INSERT INTO monthly_totals (year,month,total_upload,total_download) VALUES (?,?,0,0) ON DUPLICATE KEY UPDATE total_upload=0, total_download=0',
        [d.getFullYear(), d.getMonth()+1]
      );
      console.log('[CRON] Nouveau mois — total mensuel réinitialisé');
    } catch(e) { console.error('[CRON] Erreur reset mensuel:', e.message); }
  });

  console.log('[CRON] Jobs démarrés (vérif quota + expiration toutes les heures)');
}

// ============================================================
// DÉMARRAGE
// ============================================================
async function start() {
  const PORT = parseInt(process.env.PORT || '3000');
  let connected = false;
  for (let i = 1; i <= 3; i++) {
    console.log(`[DB] Tentative de connexion ${i}/3...`);
    connected = await initDB();
    if (connected) break;
    if (i < 3) await new Promise(r => setTimeout(r, 3000));
  }
  if (!connected) {
    console.error('[FATAL] Impossible de se connecter à MySQL après 3 tentatives.');
    console.error('[FATAL] Le serveur démarre quand même — les routes /api renverront 503');
  }
  await ensureKighmuTable().catch(e => console.warn('[SSH-RULES] nftables non disponible:', e.message));
  app.listen(PORT, '127.0.0.1', () => {
    console.log('');
    console.log('╔══════════════════════════════════════╗');
    console.log(`║   KIGHMU PANEL v2 — port ${PORT}       ║`);
    console.log('╚══════════════════════════════════════╝');
    console.log(`  → http://0.0.0.0:${PORT}/admin`);
    console.log(`  → http://0.0.0.0:${PORT}/reseller`);
    console.log(`  DB: ${connected ? 'connectée ✓' : 'ERREUR ✗'}`);
    console.log('');
  });
  if (connected) {
    await syncAllSshRules();
    await resyncV2rayClients().catch(e => console.error('[V2RAY-RESYNC] Erreur démarrage:', e.message));
    startCron();
  }
}

start().catch(e => {
  console.error('[FATAL] Erreur démarrage:', e.message);
  process.exit(1);
});
