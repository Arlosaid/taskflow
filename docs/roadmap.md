# TaskFlow — Roadmap

Plan de construcción del proyecto, en el orden en que conviene hacerlo. Marca las casillas
conforme avances. La bitácora con las explicaciones está en [`bitacora.md`](./bitacora.md).

**La regla que ordena todo:** construye el carril antes que el tren. El pipeline y la identidad
(OIDC) primero, aunque todavía no haya nada que desplegar. Así cada pieza de infra nace ya
pasando por CI, en vez de retrofitear seguridad después.

---

## Estado actual

| Pieza | Estado |
|---|---|
| `.pre-commit-config.yaml` (ruff, terraform fmt/validate/tflint/checkov/docs, gitleaks) | ✅ |
| `.tflint.hcl`, `.gitignore` | ✅ |
| `infra/bootstrap/` — bucket S3 de estado | ✅ |
| Versión del provider AWS unificada a `~> 6.0` | ✅ |
| Provider OIDC de GitHub en bootstrap + output | ✅ |
| `infra/modules/github-oidc/` — roles `plan` y `deploy` aplicados en AWS | ✅ |
| Federación OIDC verificada de punta a punta (smoke test) | ✅ |
| Todo lo demás | ⬜ |

**Siguiente acción:** pasos 6 y 7 — GitHub Environments y `pr.yml`. Con eso se cierra el Bloque B.

---

## Bloque A — Higiene (1 noche)

- [x] **1.** Unificar `required_providers` (`~> 6.0`) y `required_version` (`>= 1.11`) en todos los directorios
- [x] **2.** ~~ADRs~~ — descartado a propósito; las decisiones van en `bitacora.md`
- [ ] **3.** `Makefile` con `up` / `down` / `local` / `test` / `fmt`
- [ ] **4.** README completo: diagrama, cómo correr en local, tabla de costos, sección "Known accepted risks"

## Bloque B — Identidad y primer pipeline (1 fin de semana) ← *mayor aprendizaje*

- [x] **5.6** `var.aws_profile` con `default = null` para que dev funcione en local y en CI
- [x] **5.1/5.2** Provider OIDC en `infra/bootstrap` (recurso de cuenta, único) + output
- [x] **5.3** Módulo `infra/modules/github-oidc/` con sus cuatro archivos
- [x] **5.4** Trust policies: condiciones `aud` y `sub` para los roles `plan` y `deploy`
- [x] **5.5** Permisos: `ReadOnlyAccess` + acceso al state separado por rol (plan no escribe el state)
- [x] **5.7** Módulo consumido desde `envs/dev` y aplicado a mano
- [x] **5.8** Verificado con un workflow desechable: `assumed-role/taskflow-dev-github-deploy` ✅
- [ ] **6.** GitHub Environments `dev` y `prod`, con required reviewer en `prod`
- [ ] **7.** `.github/workflows/pr.yml`: `lint-infra` + `terraform plan` comentado en el PR

**Hito:** un PR con el plan de Terraform comentado automáticamente, autenticado sin ninguna
llave guardada — y todavía sin desplegar nada.

## Bloque C — La aplicación (2–3 noches)

- [ ] **8.** `pyproject.toml` real: `[project]` con dependencias, grupo dev, `[tool.pytest.ini_options]`
- [ ] **9.** API FastAPI mínima con `/healthz` (liveness) y `/readyz` (checa la DB)
- [ ] **10.** `Dockerfile` multi-stage (usuario no-root, `HEALTHCHECK`) + `.dockerignore` + `docker-compose.yml`
- [ ] **11.** `tests/` con conftest, `.env.example`, y job `test` añadido a `pr.yml`
- [ ] **12.** Alembic con la primera migración — **sin** correrla al arrancar la app

## Bloque D — Infra de carga (el grueso, un PR por módulo)

- [ ] **13.** `network`: VPC, subredes, security groups. Sin NAT Gateway en dev (~$32/mes) → riesgo aceptado
- [ ] **14.** `ecr`: `image_tag_mutability = "IMMUTABLE"`, `scan_on_push = true`, lifecycle policy (últimas 10)
- [ ] **15.** `database`: RDS Postgres con `manage_master_user_password = true` y **sin** atributo `password`
- [ ] **16.** `ecs`: cluster, ALB, task definition (bloque `secrets`, no `environment`), service con
      `deployment_circuit_breaker { rollback = true }`, `image_uri` como variable, y una segunda
      task definition `migrate`

## Bloque E — Pipeline de despliegue (1 fin de semana)

- [ ] **17.** `.github/workflows/deploy.yml`:
      `build → trivy (HIGH,CRITICAL, ignore-unfixed) → push tag=SHA → migrate → apply dev → [approval] → apply prod`
      con `concurrency: cancel-in-progress: false`
- [ ] **18.** `docs/runbooks/rollback.md`
- [ ] **19.** Prueba de caos: desplegar un contenedor que falle el health check y ver el rollback automático
- [ ] **20.** Cierre: "Known accepted risks" en el README + grabar 4 min en inglés narrando un deploy

---

## Preguntas de entrevista que este proyecto responde

1. ¿Cómo se autentica tu pipeline con AWS? *(OIDC, sin llaves, rol acotado por el claim `sub`)*
2. ¿Qué impide que un PR desde un fork despliegue a prod? *(condición `sub` + Environment con reviewer + rol de plan de sólo lectura)*
3. ¿Cómo obtiene el contenedor el password de la base de datos? *(bloque `secrets` con ARN, resuelto por el execution role antes de arrancar; nunca en el JSON ni en el state)*
4. ¿Dónde corren las migraciones y qué pasa durante un rolling deploy? *(tarea one-off previa; expand/contract para que ambas revisiones coexistan)*
5. ¿Cómo haces rollback? *(tags inmutables por SHA + circuit breaker con rollback automático)*
6. ¿Diferencia entre `terraform validate` y `checkov`? *(sintaxis y tipos vs misconfiguración de seguridad)*
7. CVE HIGH sin fix en tu imagen base, ¿qué haces? *(`ignore-unfixed`, documentar el riesgo, evaluar alcanzabilidad, seguir el fix upstream)*
8. ¿Por qué no usar `latest` como tag? *(sin objetivo de rollback, sin auditoría de qué corre, ambigüedad de caché)*
