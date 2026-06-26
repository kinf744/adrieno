module.exports = {
  apps: [{
    name: 'kighmu-panel',
    script: 'server.js',
    cwd: __dirname,
    max_memory_restart: '500M',
    max_restarts: 20,
    min_uptime: '10s',
    restart_delay: 3000,
    autorestart: true,
    watch: false,
    env: {
      NODE_ENV: 'production',
    },
  }],
};
