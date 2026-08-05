# TaskFlow — Roadmap

Plan de construcción del proyecto, en el orden en que conviene hacerlo. Marca las casillas
conforme avances. Las explicaciones de cada paso están en [`bitacora.md`](./bitacora.md).

**La regla que ordena todo:** construye el carril antes que el tren. El pipeline y la identidad
(OIDC) primero, aunque todavía no haya nada que desplegar. Así cada pieza de infra nace ya
pasando por CI, en vez de retrofitear seguridad después.

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
| Aplicación, tests, Docker, VPC/ECR/ECS/RDS, deploy pipeline | ⬜ |

**Siguiente acción:** Bloque A (Makefile + README, una noche) y después el Bloque C — la aplicación.

**Limpieza pendiente:** borrar `infra/modules/github-oidc/.terraform.lock.hcl` (los módulos no
son root modules y no llevan lock propio).

---

## Bloque A — Higiene (1 noche)

- [x] **1.** Unificar `required_providers` (`~> 6.0`) y `required_version` (`>= 1.11`)
- [x] **2.** ~~ADRs~~ — descartado a propósito; las decisiones van en `bitacora.md`
- [ ] **3.** `Makefile` con `fmt` / `plan` / `apply` / `local` / `test`, encapsulando el
      `export TF_VAR_aws_profile=taskflow-dev`
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

## Bloque C — La aplicación (2–3 noches)

- [ ] **8.** `pyproject.toml` real: `[project]` con dependencias, grupo dev,
      `[tool.pytest.ini_options]`
- [ ] **9.** API FastAPI mínima con `/healthz` (liveness) y `/readyz` (checa la DB)
- [ ] **10.** `Dockerfile` multi-stage (usuario no-root, `HEALTHCHECK`) + `.dockerignore` +
      `docker-compose.yml`
- [ ] **11.** `tests/` con conftest, `.env.example`, y job `test` añadido a `pr.yml`
- [ ] **12.** Alembic con la primera migración — **sin** correrla al arrancar la app

## Bloque D — Infra de carga (el grueso, un PR por módulo)

- [ ] **13.** `network`: VPC, subredes, security groups. Sin NAT Gateway en dev (~$32/mes) →
      riesgo aceptado, VPC endpoints en su lugar
- [ ] **14.** `ecr`: `image_tag_mutability = "IMMUTABLE"`, `scan_on_push = true`, lifecycle
      policy (últimas 10)
- [ ] **15.** `database`: RDS Postgres con `manage_master_user_password = true` y **sin**
      atributo `password` — el secreto nunca toca el tfstate
- [ ] **16.** `ecs`: cluster, ALB, task definition (bloque `secrets`, no `environment`), service
      con `deployment_circuit_breaker { rollback = true }`, `image_uri` como variable, y una
      segunda task definition `migrate`

## Bloque E — Pipeline de despliegue (1 fin de semana)

- [ ] **17.** `.github/workflows/deploy.yml`:
      `build → trivy (HIGH,CRITICAL, ignore-unfixed) → push tag=SHA → migrate → apply dev`
      con `concurrency: cancel-in-progress: false`
- [ ] **18.** `docs/runbooks/rollback.md`
- [ ] **19.** Prueba de caos: desplegar un contenedor que falle el health check y ver el rollback
      automático
- [ ] **20.** Cierre: "Known accepted risks" en el README + grabar 4 min en inglés narrando un
      deploy completo de commit a producción

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
