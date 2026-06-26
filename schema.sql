-- ============================================================
-- KIGHMU PANEL v2 - Base de données
-- Usage: mysql -u root -p < schema.sql
-- ============================================================
CREATE DATABASE IF NOT EXISTS kighmu_panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE kighmu_panel;

CREATE TABLE IF NOT EXISTS admins (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP NULL
);

CREATE TABLE IF NOT EXISTS resellers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    password VARCHAR(255) NOT NULL,
    email VARCHAR(100),
    max_users INT DEFAULT 10,
    used_users INT DEFAULT 0,
    data_limit_gb DECIMAL(10,2) DEFAULT 0,
    quota_blocked TINYINT(1) DEFAULT 0,
    allowed_tunnels TEXT DEFAULT NULL,  -- JSON array ex: ["vless","ssh-multi"] — NULL = tous autorisés
    expires_at TIMESTAMP NOT NULL,
    is_active TINYINT(1) DEFAULT 1,
    created_by INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (created_by) REFERENCES admins(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS clients (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    password VARCHAR(255),
    uuid VARCHAR(36),
    reseller_id INT,
    tunnel_type VARCHAR(30) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    is_active TINYINT(1) DEFAULT 1,
    quota_blocked TINYINT(1) DEFAULT 0,
    data_limit_gb DECIMAL(10,2) DEFAULT 0,
    note TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (reseller_id) REFERENCES resellers(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS usage_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    client_id INT,
    reseller_id INT,
    upload_bytes BIGINT DEFAULT 0,
    download_bytes BIGINT DEFAULT 0,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
    FOREIGN KEY (reseller_id) REFERENCES resellers(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS activity_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    actor_type ENUM('admin','reseller') NOT NULL,
    actor_id INT NOT NULL,
    action VARCHAR(100) NOT NULL,
    target_type VARCHAR(50),
    target_id INT,
    details TEXT,
    ip_address VARCHAR(45),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS monthly_totals (
    id INT AUTO_INCREMENT PRIMARY KEY,
    year INT NOT NULL,
    month INT NOT NULL,
    total_upload BIGINT DEFAULT 0,
    total_download BIGINT DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY ym (year, month)
);

CREATE TABLE IF NOT EXISTS login_attempts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    ip_address VARCHAR(45) NOT NULL,
    attempts INT DEFAULT 1,
    blocked_until TIMESTAMP NULL,
    last_attempt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_ip (ip_address)
);

-- L'admin doit être créé par le script d'installation avec un mot de passe unique
-- Ne JAMAIS laisser de hash par défaut dans le code source

-- ============================================================
-- MIGRATION pour installations existantes (décommenter si upgrade)
-- ============================================================
-- ALTER TABLE resellers ADD COLUMN IF NOT EXISTS data_limit_gb DECIMAL(10,2) DEFAULT 0;
-- ALTER TABLE clients ADD COLUMN IF NOT EXISTS data_limit_gb DECIMAL(10,2) DEFAULT 0;
-- ALTER TABLE clients ADD COLUMN IF NOT EXISTS quota_blocked TINYINT(1) DEFAULT 0;
-- ALTER TABLE resellers ADD COLUMN IF NOT EXISTS allowed_tunnels TEXT DEFAULT NULL;
-- ALTER TABLE resellers ADD COLUMN IF NOT EXISTS quota_blocked TINYINT(1) DEFAULT 0;
