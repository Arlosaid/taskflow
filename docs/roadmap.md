# TaskFlow — Roadmap

Plan de construcción del proyecto, en el orden en que conviene hacerlo. Marca las casillas
conforme avances. Las explicaciones de cada paso están en [`bitacora.md`](./bitacora.md).

**La regla que ordena todo:** construye el carril antes que el tren. El pipeline y la identidad
(OIDC) primero, aunque todavía no haya nada que desplegar. Así cada pieza de infra nace ya
pasando por CI, en vez de retrofitear seguridad después.

**Qué es la app:** un gestor real de proyectos y tareas — import masivo, reportes generados de
forma asíncrona, y (opcional) búsqueda semántica. El backend es el centro del proyecto; la
infra existe para servirlo. Cada feature está elegida para justificar un patrón de producción:
la app es útil Y cada endpoint es una respuesta de entrevista.

---

## Estado actual

**Bloque B cerrado.** Hay identidad federada y pipeline de pull request. No hay aplicación ni
infraestructura de carga.

| Pieza | Estado |
|---|---|
| `.pre-commit-config.yaml`, `.tflint.hcl`, `.gitignore` | ✅ |
| `infra/bootstrap/` — bucket S3 de estado (versioning, SSE, lifecycle, `prevent_destroy`) | ✅ |
| Versión del provider AWS unificada a `~> 6.0` en todos los directorios | ✅ |
| Provider OIDC de GitHub en bootstrap + output | ✅ |
| `infra/modules/github-oidc/` — roles `plan` y `deploy` aplicados en AWS | ✅ |
| Federación OIDC verificada de punta a punta | ✅ |
| `pr.yml` — lint + `terraform plan` comentado en el PR con el rol de sólo lectura | ✅ |
| `makefile` — `fmt`/`lint`/`plan`/`apply`/`destroy`, encapsula el perfil AWS local | ✅ |
| `pyproject.toml` + `uv.lock` — dependencias reales, grupo dev, pytest y ruff configurados | ✅ |
| `app/` — `/healthz` y `/readyz`, config por entorno, engine de SQLAlchemy | ✅ |
| `Dockerfile` multi-etapa no-root + `docker-compose.yml` con Postgres | ✅ |
| Tests, VPC/ECR/ECS/RDS, deploy pipeline, worker, Step Functions | ⬜ |

**Siguiente acción:** el punto **11** — el modelo `Project`/`Task` y la primera migración de
Alembic. El README (punto 4) queda como cierre del Bloque A: ahora ya hay algo que correr en
local que documentar, así que se puede escribir cuando apetezca.

**Reestructura 2026-08-06 (v2):** el Bloque C se amplió a backend robusto (dos recursos
relacionados, JWT, patrón async-API, query optimizada con EXPLAIN); los secretos son un paso
explícito (21); Step Functions entró como bloque propio — se usó en Dish sin entenderlo por
dentro, y cerrar ese hueco es el punto del proyecto. Criterio general: profundidad en un
sistema coherente; los servicios AWS incluidos (ECS, RDS, SQS/SNS, Lambda, Step Functions,
S3, SSM/Secrets Manager, CloudWatch) son los que más aparecen en vacantes backend.

---

## Bloque A — Higiene (1 noche)

- [x] **1.** Unificar `required_providers` (`~> 6.0`) y `required_version` (`>= 1.11`)
- [x] **2.** ~~ADRs~~ — descartado a propósito; las decisiones van en `bitacora.md`
- [x] **3.** `makefile` con `fmt` / `lint` / `plan` / `apply` / `destroy`, encapsulando el
      `export TF_VAR_aws_profile=taskflow-dev`. Los targets `local` y `test` del plan original
      quedan para el Bloque C: no hay nada que arrancar ni testear todavía (llegan con 10 y 16)
- [ ] **4.** README completo: qué es, diagrama, cómo correr en local, tabla de costos, y
      **"Known accepted risks"** (un solo entorno sin aprobación manual + los cuatro skips de
      checkov del bootstrap)

## Bloque B — Identidad y primer pipeline ✅ CERRADO

- [x] **5.6** `var.aws_profile` con `default = null` para que dev funcione en local y en CI
- [x] **5.1/5.2** Provider OIDC en `infra/bootstrap` (recurso de cuenta, único) + output
- [x] **5.3** Módulo `infra/modules/github-oidc/` con sus cuatro archivos
- [x] **5.4** Trust policies: condiciones `aud` y `sub` para los roles `plan` y `deploy`
- [x] **5.5** Permisos: `ReadOnlyAccess` + acceso al state **separado por rol** (plan no escribe
      el state, sólo el `.tflock`)
- [x] **5.7** Módulo consumido desde `envs/dev` y aplicado a mano
- [x] **5.8** Verificado con un workflow desechable: `assumed-role/taskflow-dev-github-deploy`
- [ ] **6.** GitHub Environments `dev` y `prod` con required reviewer — **aplazado, no
      descartado**. Por ahora: un solo entorno y push directo a main, que el rol `deploy` ya
      acepta vía `:ref:refs/heads/main`. El trust policy conserva a propósito los `sub` de
      `:environment:dev` y `:environment:prod`, así que activarlo mañana es crear los
      Environments en la interfaz, sin tocar Terraform. Mientras tanto no hay gate de aprobación
      manual → va a "Known accepted risks".
- [x] **7.** `.github/workflows/pr.yml`: `lint-infra` + `terraform plan` comentado en el PR

**🎉 Hito alcanzado** — un PR con el plan de Terraform comentado automáticamente, autenticado sin
ninguna llave guardada en el repositorio, y todavía sin desplegar nada.

## Bloque C — El backend (el corazón del proyecto, ~2 semanas de noches)

El orden importa: el Postgres del compose (10) es prerequisito de todo lo que sigue. Los tests
van al final para cubrir el conjunto.

- [x] **8.** `pyproject.toml` real: `[project]` con dependencias, grupo dev,
      `[tool.pytest.ini_options]` — adelantado junto con el makefile (PR #6), con `uv.lock`
      commiteado
- [x] **9.** API FastAPI mínima con `/healthz` (liveness, no toca nada) y `/readyz` (readiness,
      checa la DB). Dos endpoints y no uno: si liveness checara la DB, una caída de DB haría
      que el orquestador reinicie todos los contenedores en bucle
- [x] **10.** `Dockerfile` multi-stage (usuario no-root, `HEALTHCHECK`) + `.dockerignore` +
      `docker-compose.yml` con Postgres local. Targets `local` y `test` al makefile.
      Verificado: `readyz` → 200 con `db: ok`, contenedor como `uid=100(app)`, imagen 298 MB.
      **Cinco pulidos anotados en la bitácora [10]**, ninguno bloqueante: fijar la etapa final a
      `python:3.12-slim-bookworm`, quitar el `COPY app` muerto del builder, volumen nombrado para
      Postgres, password una sola vez con `${VAR}`, y comentarios `##` en los targets nuevos del
      makefile para que salgan en `make help`
- [ ] **11.** Modelos relacionados `Project` y `Task` (SQLAlchemy 2.0 tipado) + Alembic con la
      primera migración — **sin** correrla al arrancar la app (con 2 tasks en ECS correrían en
      carrera). Concepto a dominar desde ya: **expand/contract** — toda migración compatible
      con la versión anterior del código
- [ ] **12.** CRUD `/projects` y `/tasks`: schemas Pydantic separados del modelo ORM, códigos
      de estado correctos (201, 204, 404, 409, 422), paginación `limit`/`offset` (y saber
      narrar cursor-based), filtrado, sesión de DB por request con `Depends`, cuerpo de error
      consistente estilo **problem-details (RFC 7807)**, logs JSON estructurados desde el
      primer endpoint
- [ ] **13.** Autenticación y autorización — el punto con más superficie de ataque del proyecto:
      - **Authn:** registro/login con JWT, `Authorization: Bearer`, expiración corta, secreto
        desde settings (en AWS vendrá de SSM, punto 21). Password con **hash Argon2id o
        bcrypt** — nunca SHA, nunca texto plano. Rate limit en `/login` contra fuerza bruta
      - **Authz a nivel de objeto (BOLA):** cada query filtra por el dueño **en el `WHERE`**, no
        después en Python. Es la vulnerabilidad #1 del OWASP API Top 10 y la más preguntada: un
        `GET /tasks/42` con token válido que devuelve la tarea de otro usuario
      - **Endurecimiento del borde:** CORS explícito (nunca `allow_origins=["*"]` junto con
        credenciales), tope al `limit` de la paginación, límite de tamaño de payload, y errores
        que no filtren stack traces
      - **Nada sensible al log:** ni el token, ni el password, ni PII — redacción explícita en
        el logger estructurado del punto 12
      - Narrar el trade-off de revocación: stateless → no se revoca directo; TTL corto +
        refresh token que sí se puede revocar
- [ ] **14.** El patrón **async-API**: `POST /tasks/import` (bulk) responde `202 Accepted` +
      job id; `GET /jobs/{id}` devuelve el estado desde una tabla `jobs`. Por ahora el job se
      procesa en un BackgroundTask local — en el Bloque F lo toma el worker real por SQS. El
      contrato con el cliente no cambia: esa es la gracia del patrón
- [ ] **15.** Una query deliberadamente optimizada: provocar el **N+1** con la relación
      project→tasks, medirlo con `EXPLAIN ANALYZE` y query logging, arreglarlo (eager loading
      + índice), y documentar el antes/después en `docs/` — historia de entrevista instantánea
- [ ] **16.** `tests/` con conftest (DB de prueba), `.env.example`, y jobs `test` + `pip-audit`
      añadidos a `pr.yml`
- [ ] **17.** *(opcional)* Redis **sólo en compose local**: cache-aside en un endpoint caliente
      + rate limiting con 429 y `Retry-After`. En AWS queda talk-only — ElastiCache cuesta
      ~$12+/mes por una historia que se cuenta igual con la implementación local

## Bloque D — Infra de carga (el grueso, un PR por módulo)

- [ ] **18.** `network`: VPC, subredes públicas/privadas, security groups **encadenados** (la
      SG de la DB acepta 5432 sólo desde la SG de la app, nunca un rango IP). Sin NAT Gateway
      en dev (~$32/mes) → riesgo aceptado, VPC endpoints en su lugar
- [ ] **19.** `ecr`: `image_tag_mutability = "IMMUTABLE"`, `scan_on_push = true`, lifecycle
      policy (últimas 10)
- [ ] **20.** `database`: RDS Postgres con `manage_master_user_password = true` y **sin**
      atributo `password` — el secreto nunca toca el tfstate
- [ ] **21.** **Secretos y configuración** — el paso que más se pregunta en trabajos reales:
      - La distinción: si puede salir en un screenshot sin consecuencias es **config** (env
        vars planas: `APP_ENV`, `LOG_LEVEL`, `QUEUE_URL`); si no, es **secreto**
      - **SSM Parameter Store** `SecureString` para la llave de firma del JWT; **Secrets
        Manager** para el password de RDS (ya lo administra AWS por el punto 20)
      - En el task definition van en el bloque `secrets` (por ARN), nunca en `environment`
      - **Por qué los resuelve el execution role y no el task role:** el agente de ECS los
        inyecta *antes* de arrancar el contenedor — el plaintext jamás aparece en el JSON del
        task definition, ni en la consola, ni en el state de Terraform
      - El trade-off residual, narrado: sigue viviendo en `os.environ` del proceso; la versión
        estricta es leer de Secrets Manager en el arranque de la app con el task role
- [ ] **22.** `ecs`: cluster, ALB, task definition (bloque `secrets` del punto 21), service
      con `deployment_circuit_breaker { rollback = true }`, `image_uri` como variable, y una
      segunda task definition `migrate`

## Bloque E — Pipeline de despliegue (1 fin de semana)

- [ ] **23.** `.github/workflows/deploy.yml`:
      `build → trivy (HIGH,CRITICAL, ignore-unfixed) → push tag=SHA → migrate → apply dev`
      con `concurrency: cancel-in-progress: false`
- [ ] **24.** `docs/runbooks/rollback.md`: cómo redesplegar un SHA anterior, cómo saber qué
      revisión está viva, cómo saber si el circuit breaker ya lo resolvió solo

## Bloque F — Worker asíncrono (SNS → SQS → Lambda, 2–3 noches)

Llena `worker/` y responde el grupo de preguntas de event-driven: colas, DLQ, idempotencia.
El bulk-import del punto 14 deja de ser un BackgroundTask y pasa a procesarse aquí.

- [ ] **25.** Módulo `queue-worker`: topic SNS + cola SQS suscrita + DLQ con
      `maxReceiveCount = 3` + long polling. SNS→SQS y no SQS directo: un consumidor nuevo
      mañana es una cola más suscrita, el productor no cambia
- [ ] **26.** `worker/`: handler delgado (parsea evento → llama lógica en módulo aparte,
      testeable sin AWS) con **Lambda Powertools**: `Logger` (JSON + correlation ID),
      `Idempotency` (SQS es at-least-once → procesar dos veces = mismo resultado),
      `BatchProcessor` (sólo los mensajes fallidos vuelven a la cola). Secretos en Lambda:
      Powertools `parameters` leyendo SSM **en el init** (fuera del handler, cacheado con TTL)
- [ ] **27.** Empaquetado como **imagen de contenedor** en ECR — misma cadena
      build→trivy→push→SHA que la app, una sola historia de empaquetado. Layers descartadas
      con razón escrita → bitácora Parte 5. Rol IAM propio por función, mínimo privilegio.
      Deploy del worker añadido a `deploy.yml`

## Bloque G — Step Functions: el workflow de reportes (1 fin de semana + noches)

Se usó en Dish sin verlo por dentro — este bloque cierra ese hueco construyéndolo de cero.
La pregunta que responde: ¿por qué un orquestador y no encadenar Lambdas con código? Porque
ahí los reintentos, el estado y el manejo de errores viven dispersos; un crash a media cadena
pierde el estado. La máquina lo hace explícito, observable y reanudable.

- [ ] **28.** State machine `report-generation`: `ValidateRequest → FetchData →
      GenerateReport → StoreInS3 → NotifyUser`, con camino de compensación
      (`MarkReportFailed`) en el Catch — la versión ligera del **patrón Saga**. La definición
      ASL vive en Terraform (`aws_sfn_state_machine` con plantilla) — versionada y revisable
      en PRs
- [ ] **29.** Las prácticas que separan esto de un tutorial:
      - **Retry + Catch por estado** con backoff y max attempts — cada paso falla distinto,
        nada de un try/catch global
      - **Direct SDK integrations**: `StoreInS3` y `NotifyUser` llaman S3/SNS directo desde la
        máquina, sin Lambda de pegamento — menos código, menos costo, menos cold starts
      - **Map state** para fan-out: un reporte por proyecto, en paralelo
      - Timeout en cada estado; ejecución **idempotente de punta a punta** (segura de relanzar)
      - **Standard vs Express**, documentado: Standard aquí (auditable, exactly-once, 1 año
        max); Express para volumen alto y corta duración
- [ ] **30.** Disparo desde la API: `POST /reports` → `202` + ARN de ejecución;
      `GET /reports/{id}/status` consulta el estado. X-Ray habilitado para ver el flujo
      API → SFN → Lambda completo

## Bloque H — Observabilidad y resiliencia (1 fin de semana)

Responde "¿cómo te enteras de que algo se rompió?" — sin esto, todo lo anterior es fe.

- [ ] **31.** Correlation ID propagado por todo el flujo (API → SNS → SQS → Lambda → SFN),
      retención explícita en todos los log groups
- [ ] **32.** Alarmas: 5xx del ALB, DLQ > 0, `ExecutionsFailed` de la state machine +
      presupuesto AWS con alerta. Alertar por síntomas, no por causas (error rate, no CPU%)
- [ ] **33.** Prueba de caos: desplegar un contenedor que falle el health check → ver el
      rollback automático; romper el worker (negarle un permiso IAM) → ver la DLQ llenarse,
      la alarma disparar y `ExecutionsFailed` encenderse. **Post-mortem de 1 página en
      inglés** — casi ningún candidato mid tiene uno
- [ ] **34.** Cierre: "Known accepted risks" consolidados en el README + grabar 4 min en
      inglés narrando un deploy completo de commit a producción

## Bloque I — *(opcional)* RAG-lite: pgvector + Bedrock (1 fin de semana)

No es pivote a ML: es un servicio backend con una dependencia externa poco confiable. Da "RAG"
y "vector search" con trabajo real detrás, a costo de centavos.

- [ ] **35.** `pgvector` en el RDS existente (cero infra nueva); embedding de título+descripción
      vía Bedrock al crear/actualizar una tarea, guardado en columna `vector`
- [ ] **36.** `GET /tasks/search?q=` semántico (`ORDER BY embedding <=> :q LIMIT 5`) y la
      comparación documentada contra el keyword search — esa comparación ES la historia de
      entrevista
- [ ] **37.** `POST /ai/ask`: pregunta → retrieve top-K → prompt con contexto → Claude vía
      Bedrock responde **sólo** desde el contexto, citando los IDs fuente. Producción, no
      tutorial: timeout + retry + fallback (el LLM nunca tumba la API), tokens y latencia como
      métricas, prompt versionado en el repo, límites de input

---

## Hilo de seguridad (transversal)

No es un bloque aparte: son controles que entran dentro de los puntos de arriba. La tabla existe
para poder auditar de un vistazo que ninguno se quedó fuera.

| Control | Dónde entra | Estado |
|---|---|---|
| Federación OIDC, cero llaves guardadas en el repo | 5.x | ✅ |
| Dos roles IAM con policy documents **separados** | 5.5 | ✅ |
| `validate` + `tflint` + `checkov` en CI, sin `soft_fail` | 7 | ✅ |
| **gitleaks también en CI**, no sólo en pre-commit — un hook local se salta con `--no-verify` | 16 | ⬜ |
| **Actions ancladas a SHA**, no a `@master`: hoy `checkov-action@master` es una referencia móvil, y quien controle esa rama corre código en tu pipeline | 16 | ⬜ |
| Hash de password, BOLA, CORS, redacción de logs | 13 | ⬜ |
| `pip-audit` (dependencias) + `trivy` (imagen) con gate HIGH/CRITICAL | 16, 23 | ⬜ |
| Contenedor: usuario no-root, **filesystem raíz de sólo lectura**, sin capabilities extra | 10, 22 | ⬜ |
| Subredes privadas + SG encadenadas + RDS sin acceso público | 18, 20 | ⬜ |
| **Cifrado en reposo, explícito y no por defecto**: RDS `storage_encrypted`, SSE en SQS y en el bucket de reportes, retención declarada en los log groups | 18–22 | ⬜ |
| Secretos por ARN resueltos por el execution role; nunca en el state | 21 | ⬜ |
| ECR con tags inmutables + `scan_on_push` | 19 | ⬜ |
| **Alcance del rol `deploy`**: crecerá para crear VPC/ECS/RDS. La tentación es `AdministratorAccess`; la disciplina es acotarlo por servicio y escribir por qué | 18–22 | ⬜ |
| Alarmas de DLQ, 5xx y presupuesto | 32 | ⬜ |

### Riesgos aceptados — van al README (punto 4)

1. **Sin HTTPS real.** El ALB expone su DNS de AWS y un certificado ACM necesita un dominio, que
   quedó fuera de alcance. Consecuencia honesta que hay que escribir: **el JWT viaja en claro.**
   Se acepta porque no hay usuarios ni datos reales — pero se acepta *dicho*, no por omisión.
2. **Sin gate de aprobación manual** (punto 6 aplazado): un push a `main` despliega solo.
3. **El rol `plan` tiene `ReadOnlyAccess` sobre toda la cuenta**, y un pull request es código que
   su autor controla — `terraform plan` puede ejecutar código (un `data "external"`, un provider
   apuntado a otro sitio). En un repo de una persona el riesgo es bajo, pero es justo el
   escenario que hay que saber nombrar: *quien pueda abrir un PR puede leer todo lo que lee
   `ReadOnlyAccess`, incluido `s3:GetObject` sobre cualquier bucket de la cuenta.* La mitigación
   real, si alguna vez hay colaboradores: acotar el rol `plan` a los servicios del proyecto en
   vez de usar la política administrada.
4. **Sin WAF, sin Multi-AZ, sin NAT Gateway** — costo por encima de defensa en profundidad, en
   un entorno sin datos reales.

---

## Fuera de alcance a propósito (talk-only)

Se preparan como respuestas habladas (2–3 frases en inglés cada una), no se construyen.
Una noche. El detalle conceptual está en la guía de estudio.

| Tema | Por qué no se construye |
|---|---|
| Redis en AWS (ElastiCache) | La implementación local del punto 17 cuenta la misma historia sin la factura |
| Kubernetes / EKS | Señal de DevOps/platform, no de backend mid. Extensión futura: `kind` local si sobra tiempo |
| CloudFront / Route 53 / dominio | Proyecto API, no contenido estático global. HTTPS con dominio → riesgo aceptado |
| Multi-región DR | Enterprise theater en un portafolio; saber hablar de RTO/RPO basta |
| Kafka vs SQS | Conceptual: log retenido/replay/consumer groups vs cola administrada |
| Auth0 / Cognito como proveedor de identidad | Integrar un IdP es trabajo de consola, no un concepto nuevo. Firmar y verificar el JWT a mano (punto 13) enseña la mecánica que preguntan. Hay que dominar el vocabulario — OAuth2 authorization code + PKCE, OIDC vs OAuth2, validar contra un JWKS ajeno — y saber decir cuándo se delega. Si una vacante nombra Cognito, es un fin de semana cambiarlo: el `Depends` que valida el token es el único punto que se toca |
| DynamoDB más allá de idempotencia | El punto 26 lo usa como tabla de idempotencia — suficiente para narrar partition key, TTL y access patterns |

---

## Preguntas de entrevista que este proyecto responde

Las respuestas desarrolladas están en la Parte 6 de la [bitácora](./bitacora.md).

| # | Pregunta | ¿Ya la respondo? |
|---|---|---|
| 1 | ¿Cómo se autentica tu pipeline con AWS? | ✅ |
| 2 | ¿Qué impide que un PR despliegue a producción? | ✅ |
| 3 | ¿Cómo obtiene el contenedor el password de la base de datos? | ⬜ Bloque D |
| 4 | ¿Dónde corren las migraciones durante un rolling deploy? | ⬜ Bloque E |
| 5 | ¿Cómo haces rollback de un deploy malo? | ⬜ Bloque E |
| 6 | ¿Diferencia entre `terraform validate` y `checkov`? | ✅ |
| 7 | CVE HIGH sin fix en tu imagen base, ¿qué haces? | ⬜ Bloque E |
| 8 | ¿Por qué no usar `latest` como tag? | ⬜ Bloque E |
| 9 | ¿Cómo revocas un JWT? (no puedes — narra el trade-off) | ⬜ Bloque C |
| 10 | ¿Cómo encontrarías una query lenta? (EXPLAIN, N+1, before/after real) | ⬜ Bloque C |
| 11 | ¿Cómo diseñas un endpoint que tarda minutos? (async-API, 202 + status) | ⬜ Bloque C |
| 12 | ¿Por qué un mensaje de SQS puede llegar dos veces y qué haces al respecto? | ⬜ Bloque F |
| 13 | ¿Layers o imagen de contenedor para Lambda, y por qué? | ⬜ Bloque F |
| 14 | ¿Por qué Step Functions y no encadenar Lambdas con código? | ⬜ Bloque G |
| 15 | ¿Standard o Express, y qué pasa cuando un paso del workflow falla? | ⬜ Bloque G |
| 16 | ¿Cómo te enteras de que un deploy rompió algo? | ⬜ Bloque H |
| 17 | ¿Qué es RAG y cómo evitas que el modelo alucine? | ⬜ Bloque I |
| 18 | ¿Cuál es la vulnerabilidad #1 de una API y cómo la evitas? | ⬜ Bloque C |
| 19 | ¿Cómo guardas un password, y por qué no basta con SHA-256? | ⬜ Bloque C |
| 20 | ¿Qué puede hacer un pull request malicioso en tu pipeline? | ✅ documentado |
