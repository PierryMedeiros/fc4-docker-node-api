// Init de produção da imagem distroless (sem shell).
//
// Fluxo: aplica as migrações (processo filho de curta duração) e, se tudo der
// certo, carrega o servidor no MESMO processo via require(). Como este arquivo
// é o PID 1 do container, os handlers de SIGTERM/SIGINT registrados por
// dist/server.js passam a valer para o PID 1 — garantindo o encerramento
// gracioso em menos de 10s exigido pelo desafio.
//
// O código da aplicação não é alterado: apenas orquestramos migrate + server.
const { spawnSync } = require('node:child_process');

const migrate = spawnSync(process.execPath, ['dist/db/migrate.js'], {
  stdio: 'inherit',
});

if (migrate.status !== 0) {
  console.error('Migrações falharam; abortando a subida da aplicação.');
  process.exit(migrate.status ?? 1);
}

// Carrega o servidor no processo atual (PID 1). O app.listen() mantém o event
// loop vivo e os handlers de sinal ficam ativos neste processo.
require('./dist/server.js');
