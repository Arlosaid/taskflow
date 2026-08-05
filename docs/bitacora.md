# Bitácora de TaskFlow

Registro de **qué construí, por qué lo decidí así, qué aprendí y qué se me rompió**. Escrito para
mi yo del futuro: cuando el proyecto esté terminado y tenga que explicarlo, esto es lo que se me
va a haber olvidado.

## Cómo está organizado

| Parte | Contiene | Cuándo la consulto |
|---|---|---|
| **1. Mapa** | Qué existe hoy en el repo y cómo encaja | Para reubicarme después de un parón |
| **2. Conceptos** | La teoría, agrupada por tema | Para repasar antes de una entrevista |
| **3. Bitácora** | Una entrada por paso, en orden | Para recordar *por qué* decidí algo |
| **4. Problemas** | Síntoma → causa → arreglo | Cuando algo falla y me suena de antes |
| **5. Descartes** | Lo que decidí NO hacer, y por qué | Para no repensar lo ya pensado |
| **6. Entrevista** | Preguntas con respuesta, hechas desde este proyecto | Preparación |

**Regla de escritura:** la entrada se escribe **en el momento**, no al final. La razón de una
decisión se olvida mucho antes que la decisión.

**Plantilla para entradas nuevas:**

```markdown
## [N] Título

**Qué hice:** una o dos frases.
**Por qué así:** la decisión y qué descarté.
**Concepto:** lo que no sabía antes.
**Trampa:** lo que me costó tiempo o casi me sale mal.
```

---
---

# Parte 1 — Mapa del proyecto

## Estado a día de hoy

Cerrado el **Bloque B**: existe identidad federada y un pipeline de pull request. No existe
todavía ni aplicación ni infraestructura de carga.

```
taskflow/
├── .github/workflows/
│   └── pr.yml                    # lint + terraform plan comentado en cada PR
│
├── infra/
│   ├── bootstrap/                # ⚠️ backend LOCAL. Se aplica a mano. Cosas de cuenta.
│   │   └── main.tf               #    bucket de estado S3 + provider OIDC de GitHub
│   │
│   ├── modules/
│   │   └── github-oidc/          # dos roles IAM: plan (sólo lectura) y deploy
│   │
│   └── envs/dev/                 # backend S3. El único entorno. Consume módulos.
│       └── main.tf               # data lookups + module "github_oidc"
│
├── .pre-commit-config.yaml       # ruff, terraform fmt/validate/tflint/checkov/docs, gitleaks
├── .tflint.hcl
├── CLAUDE.md                     # contexto del repo para sesiones de IA
└── docs/
    ├── roadmap.md                # los 20 pasos, con casillas
    └── bitacora.md               # este archivo
```

Vacíos a propósito por ahora: `app/`, `worker/`, `k8s/`.

## El flujo de identidad, de un vistazo

Es lo único que funciona de punta a punta, así que conviene tenerlo claro:

```
   ┌─────────────────┐
   │ GitHub Actions  │  1. el job pide un token
   │      job        │ ────────────────────────┐
   └─────────────────┘                         ▼
            ▲                        ┌───────────────────┐
            │                        │  GitHub OIDC      │  2. emite un JWT firmado
            │                        │  provider         │     con claims: aud, sub, ref…
            │                        └───────────────────┘
            │                                  │
            │  5. credenciales                 │ 3. AssumeRoleWithWebIdentity(JWT)
            │     temporales (1 h)             ▼
            │                        ┌───────────────────┐
            └────────────────────────│      AWS STS      │
                                     └───────────────────┘
                                               │ 4. verifica la firma contra el
                                               │    aws_iam_openid_connect_provider,
                                               │    y evalúa el TRUST POLICY del rol
                                               ▼
                          ┌────────────────────────────────────┐
                          │ taskflow-dev-github-plan   (PRs)   │  ReadOnlyAccess + lock
                          │ taskflow-dev-github-deploy (main)  │  + escritura del state
                          └────────────────────────────────────┘
```

**Lo que yo construí en Terraform son sólo los pasos 3 y 4**: el ancla de confianza y las reglas
de quién puede entrar. Los pasos 1, 2 y 5 son de GitHub y AWS.

---
---

# Parte 2 — Conceptos

## 2.1 · Terraform — estado y backend

**El state** es el mapa entre mi código y los objetos reales de AWS. Contiene IDs, ARNs y a veces
valores sensibles. Por eso el bucket que lo guarda **nunca** puede ser público, y por eso lleva
versioning: es el botón de deshacer si un apply lo corrompe.

**La regla más importante de organización:** *un objeto de AWS debe estar en un solo state.* Si
dos states creen que gestionan el mismo recurso, se pisan — uno lo crea, el otro falla al
intentar crearlo, o peor, uno lo destruye porque no lo ve en su configuración.

De ahí la jerarquía del proyecto:

| Directorio | Qué guarda | Cadencia |
|---|---|---|
| `infra/bootstrap/` | cosas de **cuenta**, únicas (bucket de estado, provider OIDC) | a mano, casi nunca |
| `infra/envs/<env>/` | cosas **por entorno** (roles, VPC, ECS) | por CI, continuamente |

**El huevo-y-gallina de bootstrap:** ese directorio crea el bucket donde todos los demás guardan
su estado, así que él no puede guardar el suyo ahí. Usa backend **local** a propósito. Es uno de
los dos `terraform apply` manuales legítimos del proyecto.

**Locking.** Mi backend usa `use_lockfile = true`: locking nativo de S3, sin tabla DynamoDB. Es
más simple, pero tiene una consecuencia que no es obvia y que condiciona los permisos de IAM →
ver 2.4.

## 2.2 · Terraform — módulos, `data` vs `resource`, direcciones

**Un módulo es una función.** Entra por `variables`, sale por `outputs`, lo de dentro es privado.

Por eso **nunca lleva bloque `provider` ni `backend`**: los hereda de quien lo llama. Si metes un
`provider` dentro, el módulo queda atado a una región y unas credenciales concretas, deja de ser
reutilizable, y Terraform te bloquea usar `for_each` sobre él.

El `versions.tf` de un módulo declara qué provider **necesita**, no cuál usa. Es una restricción,
no una instanciación.

**`data` vs `resource` — la distinción de base:**

| | Qué hace |
|---|---|
| `resource` | Terraform **gestiona el ciclo de vida**: crea, modifica, destruye |
| `data` | Terraform sólo **lee** algo que ya existe. Nunca lo toca |

En mi repo el provider OIDC es un `resource` en bootstrap y un `data` en `envs/dev`: el mismo
objeto de AWS, bootstrap lo posee, dev sólo lo consulta.

**Caso especial:** `aws_iam_policy_document` es un `data` que **no llama a AWS**. Sólo renderiza
JSON. Se usa en vez de `jsonencode` porque da validación en `terraform validate` y un diff
legible en el plan.

**Direcciones y renombrados.** Terraform identifica los recursos por su **dirección**
(`aws_iam_role_policy.plan_state`), no por el nombre que tienen en AWS. Renombrar la etiqueta es,
por defecto, **destruir y crear**. En una policy inline da igual; en una base de datos te borra
los datos. Para eso existe el bloque `moved`:

```hcl
moved {
  from = aws_iam_role_policy.plan_state
  to   = aws_iam_role_policy.plan_state_access
}
```

**Regla derivada: leer siempre el motivo del destroy antes de aprobar un plan.** "2 to destroy"
no dice nada; el comentario `# (because ... is not in configuration)` sí.

## 2.3 · Terraform — versiones y locks

Tres cosas que se confunden:

| | Qué fija |
|---|---|
| `required_version` | la versión del **binario** de Terraform |
| `required_providers` | la versión del **plugin** del proveedor (AWS) |
| `.terraform.lock.hcl` | los **hashes exactos** de los plugins resueltos |

El lock se **commitea**, igual que un `package-lock.json`: es lo que garantiza que CI y mi laptop
resuelvan exactamente lo mismo.

**Sólo los *root modules* tienen lock.** Un módulo en `infra/modules/` no es un root module: no
tiene backend propio ni lock propio. Si aparece uno ahí, es que corrí `terraform init` dentro del
módulo por error.

## 2.4 · IAM — las dos políticas, y el acceso al state

**La distinción que más se confunde.** Hay **dos políticas por rol** y hacen cosas distintas:

| | Dónde va | Responde a |
|---|---|---|
| **Trust policy** | `assume_role_policy` del rol | **¿QUIÉN puede convertirse en este rol?** |
| **Permission policy** | attachment o `aws_iam_role_policy` | **¿QUÉ puede hacer una vez que ya lo es?** |

OIDC vive **enteramente** en el trust policy. El permission policy ni se entera de que GitHub
existe.

**Attachment vs inline:**

- `aws_iam_role_policy_attachment` → conecta una política que existe por separado y es
  compartible (ej. la managed `ReadOnlyAccess` de AWS).
- `aws_iam_role_policy` → **inline**: pertenece al rol y muere con él. No reutilizable.

Uso inline para el acceso al state porque es específica de cada rol; attachment para
`ReadOnlyAccess` porque es de AWS y no tiene sentido duplicarla.

**El detalle contraintuitivo del `.tflock`.** Un rol "de sólo lectura" **necesita `PutObject`**.
Con `use_lockfile = true`, `terraform plan` crea un objeto `.tflock` en S3 para adquirir el lock
y lo borra al terminar. Sin ese permiso, el plan muere antes de empezar.

Pero acotado a *exactamente* esa clave, nunca al bucket entero. El resultado:

| | `GetObject` state | `PutObject` state | `PutObject` .tflock |
|---|---|---|---|
| `plan` | ✅ | ❌ | ✅ |
| `deploy` | ✅ | ✅ | ✅ |

**Esa tabla es la respuesta a "¿qué impide que un pull request corrompa tu infraestructura?".**

**Los nombres de rol de IAM son globales por cuenta.** Todo nombre debe llevar el entorno
(`taskflow-dev-github-plan`) o un segundo entorno en la misma cuenta colisiona con
`EntityAlreadyExists`.

## 2.5 · OIDC — el flujo y dónde está la seguridad

El diagrama está en la Parte 1. Lo que hay que saber decir en voz alta:

> No hay llaves guardadas porque la identidad no es un secreto compartido, es una **firma
> criptográfica que se verifica en cada ejecución**. Nada que rotar, nada que filtrar.

### Las dos condiciones del trust policy

- **`aud = sts.amazonaws.com`** → "este token fue emitido *para* STS". Protege contra reutilizar
  un token que GitHub emitió para otro servicio.
- **`sub`** → "viene de *este* repo, en *esta* circunstancia". **Es la frontera de seguridad real.**

### La forma del claim `sub`

| Cómo dispara el job | Sufijo del `sub` |
|---|---|
| `on: pull_request` | `:pull_request` |
| `on: push` a main, **sin** `environment:` | `:ref:refs/heads/main` |
| job **con** `environment: prod` | `:environment:prod` |
| tag | `:ref:refs/tags/v1.0.0` |

**Trampa:** en cuanto un job declara `environment:`, el `sub` toma la forma `environment:` y **la
rama desaparece del claim**. No es "main *y además* prod" — es sólo lo segundo.

### ⚠️ Immutable subject claims — este repo NO usa el formato clásico

El prefijo del `sub` de este repositorio es:

```
repo:Arlosaid@99146811/taskflow@1316477490
```

en vez del clásico `repo:Arlosaid/taskflow`. GitHub aplica este formato **por defecto a los
repositorios creados después del 15 de julio de 2026**, e incorpora el **ID numérico del
propietario** y el **ID del repositorio**.

**Por qué existe:** un nombre de repo u organización se puede **renombrar**, y alguien puede
registrar después el nombre que quedó libre. Un trust policy anclado a `repo:Arlosaid/taskflow`
seguiría al *nombre*, no a mi repositorio. Los IDs numéricos son inmutables y no se pueden
reclamar. Es una mejora real de seguridad.

**La regla que generalizo:** nunca ensamblar el `sub` a mano desde el nombre del repo. **Sacar el
literal de un token decodificado.** El token es la única fuente de verdad; la documentación y los
blogs envejecen.

Por eso el módulo recibe `github_subject_prefix` como variable con el literal ya resuelto, en vez
de construirlo — así el código lleva la advertencia encima.

### El error a saber nombrar

`repo:Arlosaid/taskflow:*` parece inofensivo y no lo es: hace match con **cualquier** rama.
Cualquiera que consiga pushear una rama al repo puede asumir el rol de despliegue. El comodín
convierte una frontera de seguridad en decoración. Por eso uso `StringEquals`, no `StringLike`.

### Dos roles, no uno

- **`plan`** — sólo lectura, asumible desde pull requests. Un PR malicioso, como mucho, corre un plan.
- **`deploy`** — permisos de apply, asumible sólo desde `main` / los Environments.

Sobre forks: GitHub restringe fuertemente los permisos del token en PRs desde forks, así que en
la práctica un fork no obtiene el token. Pero **no dependo de eso** — el rol de plan es de sólo
lectura de todas formas. Dos capas, no una.

### `max_session_duration = 3600`

Las credenciales caducan en 1 hora. Cuanto más corta la sesión, menor la ventana si algo se filtra.

## 2.6 · Credenciales de AWS — la cadena y cómo leer los errores

**La cadena estándar de credenciales**, en orden de precedencia:

```
1. variables de entorno (AWS_ACCESS_KEY_ID, …)   ← ganan siempre
2. perfil del archivo (~/.aws/credentials)
3. metadata de la instancia (EC2 / ECS / Lambda)
```

**Que las variables de entorno vayan primero es el mecanismo que hace funcionar OIDC en CI**
(`configure-aws-credentials` las exporta). Pero en local juega en contra: un `AWS_ACCESS_KEY_ID`
viejo exportado en el shell rompe todo aunque el `profile` esté bien puesto.

→ Primer sitio donde mirar ante cualquier problema de credenciales: `env | grep -i AWS`.

**`null` vs `"null"` vs `""`.** El provider trata `null` como *"argumento no especificado"* y cae
a la cadena. Las otras dos formas **no**:

| Valor | Qué hace |
|---|---|
| `null` | ✅ argumento no especificado → cadena estándar |
| `"null"` | ❌ busca un perfil llamado literalmente `null` |
| `""` | ❌ busca un perfil con nombre vacío |

**Cómo leer cada error — ahorra horas:**

| Error | Significa |
|---|---|
| `InvalidClientTokenId` | Se encontraron credenciales, **AWS no reconoce la access key** |
| `SignatureDoesNotMatch` | La key existe, **el secreto está mal** |
| `no valid credential sources` | **No se encontró ninguna** credencial |
| `ExpiredToken` | Credenciales temporales **caducadas** |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | El trust policy rechazó: casi siempre el `sub` |

## 2.7 · GitHub Actions

**Triggers — reglas distintas, y es fácil mezclarlas:**

| Trigger | De dónde se lee el workflow |
|---|---|
| `pull_request` | de la **rama del PR** → el propio PR que introduce el archivo ya lo ejecuta |
| `workflow_dispatch` | sólo aparece en la pestaña Actions si el archivo está en la **rama por defecto** |

**`permissions: id-token: write` es obligatorio** para OIDC. Sin él GitHub ni emite el token, y
el mensaje de error no lo dice claramente. Es el error #1 de todo el mundo.

**`concurrency`** — la dirección correcta depende del workflow:

| Workflow | `cancel-in-progress` | Por qué |
|---|---|---|
| `pr.yml` | `true` | un plan de un commit ya superado no le sirve a nadie |
| `deploy.yml` | **`false`** | cancelar un apply a medias hace daño; dos apply peleando por el lock es un incidente |

**GitHub Environments** sirven para dos cosas: reviewer obligatorio y secretos por entorno. Y
enganchan con OIDC de forma elegante: un job con `environment: prod` **no arranca** hasta que
alguien aprueba, y sólo entonces GitHub emite el token con ese claim. **La aprobación humana y la
frontera criptográfica son la misma cosa**, no dos controles separados.

## 2.8 · Herramientas — qué detecta cada una

| Herramienta | Detecta | Ejemplo |
|---|---|---|
| `terraform fmt` | sólo formato | indentación inconsistente |
| `terraform validate` | sintaxis y tipos, **sin llamadas a la nube** | variable no declarada, tipo equivocado |
| `tflint` | corrección específica del provider | tipo de instancia inválido, argumento deprecado |
| `checkov` / `tfsec` | **misconfiguración de seguridad** | bucket sin cifrar, SG abierto a `0.0.0.0/0` |
| `trivy` (imagen) | CVEs en paquetes del SO y dependencias | `libssl` vulnerable en la imagen base |
| `gitleaks` | credenciales commiteadas | una llave de AWS en un notebook |
| `pip-audit` | dependencias de Python vulnerables | CVE conocido en una librería fijada |

**La lección grande del Bloque B:** hay una **clase entera de fallos que ninguna de ellas
detecta** — los que dependen de *dónde* se ejecuta el código, no de qué dice. Los tres problemas
que más tiempo me costaron (el `profile` fijo, el `sub` con immutable claims, y las credenciales
locales) dieron **`terraform validate` en verde**.

Por eso el smoke test no es opcional: es la única verificación que prueba el entorno real.

**Sobre las supresiones de checkov:** siempre inline y siempre con razón escrita. Un revisor
confía más en una supresión justificada que en un reporte limpio. Lo que no se vale es suprimir
sin explicar.

---
---

# Parte 3 — Bitácora cronológica

## [0] El backend de estado — `infra/bootstrap/`

**Qué hice:** un bucket S3 para el state con versioning, cifrado SSE-S3, public access block
completo, lifecycle de 90 días para versiones antiguas, y `prevent_destroy = true`.

**Decisiones:**
- **Backend local, a propósito** — es la raíz del huevo-y-gallina (ver 2.1).
- **SSE-S3 (AES256) en vez de un CMK de KMS** — es gratis; un CMK añade costo y gestión de llaves
  sin beneficio real a esta escala.
- **`use_lockfile = true` en vez de tabla DynamoDB** — más simple, una pieza menos que mantener.
- **Versioning encendido** — botón de deshacer.

**Las cuatro supresiones de checkov** de `main.tf` llevan razón escrita: replicación
cross-region, access logging, notificaciones de eventos y KMS. Todas fuera de alcance y todas
explicadas.

## [1] Unificar las versiones del provider

**Qué hice:** `~> 6.0` y `required_version >= 1.11` en bootstrap, `envs/dev` y el módulo.

**Por qué:** bootstrap estaba en `~> 5.60` y dev en `~> 6.0`. Dos providers distintos en el mismo
repo producen comportamientos distintos ante el mismo HCL. Es el tipo de inconsistencia que un
revisor nota inmediatamente.

→ Concepto en 2.3.

## [5.6] `aws_profile` opcional — que dev sirva en local y en CI

**Qué hice:** el `default` de `var.aws_profile` pasó de `"taskflow-dev"` a `null`.

**Por qué:** en mi máquina el provider debe usar el perfil local. En GitHub Actions no hay ningún
perfil — las credenciales llegan por variables de entorno. Con un `profile` fijo, el provider
ignora esas variables, busca un archivo que en el runner no existe, y falla.

**Trampa que me pasó:** escribí `default = "null"`, con comillas. Ver la tabla en 2.6.

**Trampa #2, la que más vale:** ninguna herramienta detecta este error. Es un error de
**entorno**, no de código → ver 2.8.

**Consecuencia diaria:** en local hay que exportar `TF_VAR_aws_profile=taskflow-dev` (Terraform
lee cualquier `TF_VAR_<nombre>`). No puedo commitear un `.tfvars` porque `.gitignore` los
bloquea, y está bien que lo haga.

## [5.1 / 5.2] El provider OIDC vive en bootstrap

**Qué hice:** `aws_iam_openid_connect_provider` en `infra/bootstrap/main.tf`, con su output.

**Por qué ahí:** es un recurso de cuenta, único. En `envs/dev` colisionaría el día que exista
`envs/prod` → ver 2.1.

**Sobre `thumbprint_list`:** lo omití. Es opcional en el provider AWS v5+; desde 2023 AWS valida
el certificado de GitHub contra sus CAs raíz de confianza. Ese hash largo que sale en todos los
blogs ya no es un control de seguridad real — es un vestigio.

## [5.3] El módulo `github-oidc`

Cuatro archivos: `variables.tf`, `main.tf`, `outputs.tf`, `versions.tf`. Cinco inputs: `env`,
`github_subject_prefix`, `oidc_provider_arn`, `state_bucket_arn`, `state_key_prefix`.

→ Concepto de módulo en 2.2.

## [5.4 / 5.5] Trust policies y permisos

Los dos trust policies (2.5) y los dos permission policies separados (2.4).

**Decisiones propias que tomé y mantengo:**
- `github_repository` como una sola variable en vez de `github_org` + `github_repo`. *(Después
  reemplazada por `github_subject_prefix` — ver [5.8].)*
- `state_key_prefix` como variable (`"dev/"`) en vez de derivarlo de `env`. Más explícito.
- Condición `s3:prefix` sobre el `ListBucket`, acotándolo a `dev/*` en vez de al bucket entero.
  Estrictamente más restrictivo de lo necesario.

**Dos errores que cometí aquí** → ver Problemas #2 y #3.

## [5.7] El apply

**Qué hice:** apliqué el módulo a mano con mi perfil local. Quedaron `taskflow-dev-github-plan` y
`taskflow-dev-github-deploy`.

**Este apply manual está bien y es inevitable:** CI no puede crear el rol que CI necesita para
autenticarse. Junto con bootstrap, es el último `terraform apply` manual legítimo del proyecto.

**Lo que aprendí leyendo el plan** → Problemas #5 y #6.

## [5.8] El smoke test

**Qué hice:** un workflow desechable con `workflow_dispatch` que sólo asume el rol y corre
`aws sts get-caller-identity`. Resultado final:

```
arn:aws:sts::654740195516:assumed-role/taskflow-dev-github-deploy/...
```

`assumed-role` y `arn:aws:sts::` (no `iam::`) = credenciales temporales obtenidas por federación,
cero secretos en el repositorio.

**Por qué probé `deploy` y no `plan`:** un `workflow_dispatch` en main emite
`:ref:refs/heads/main`, que coincide con deploy. El de plan sólo acepta `:pull_request` y no se
puede ejercitar desde ahí — se estrenó con el PR real del paso 7.

**Falló la primera vez** → Problema #7, el hallazgo más importante del Bloque B.

**Y después falló en local por credenciales** → Problema #8, que me costó la tarde.

**Borré el workflow al terminar.** Decodificaba un JWT y lo imprimía; no quiero eso corriendo
indefinidamente.

## [6] Environments — aplazados, no descartados

Decidí **un solo entorno y push directo a main**. No hacen falta Environments: el rol `deploy` ya
acepta `sub = ...:ref:refs/heads/main`.

**Pero dejé a propósito los `sub` de `:environment:dev` y `:environment:prod` en el trust
policy.** No son un riesgo —si el Environment no existe, GitHub no puede emitir un token con ese
claim— y significan que el día que quiera el gate de aprobación sólo tengo que crear el
Environment en la interfaz, **sin tocar Terraform**.

**Lo que pierdo, dicho como decisión y no como olvido:** no hay aprobación manual antes de
producción. Va a "Known accepted risks" del README.

## [7] `pr.yml` — el pipeline antes que la infraestructura

**Qué hice:** un workflow de pull request con dos jobs, `lint-infra` y `plan`, que comenta el
diff de Terraform en el PR. **Cierra el Bloque B.**

**El hito:** un PR con el plan comentado automáticamente, autenticado sin ninguna llave guardada,
y todavía sin haber desplegado nada de aplicación. El carril antes que el tren.

**Decisiones de diseño y su porqué:**

| Decisión | Por qué |
|---|---|
| `needs: lint-infra` | el lint no toca AWS. Si el formato está roto, no federar un token. **Fallar barato primero** |
| `continue-on-error` + `exit 1` final | si el plan falla quiero **ver el error en el PR**, no enterrado en los logs |
| Marcador HTML `<!-- terraform-plan-dev -->` | encuentra el comentario anterior y lo **actualiza**. Quince comentarios de plan son ruido; uno vivo es una herramienta |
| `cancel-in-progress: true` | ver 2.7 — en deploy será `false` |
| `-lock-timeout=5m` | si otro plan tiene el `.tflock`, esperar en vez de morir |
| `init -backend=false` en el lint | `validate` no necesita state ni credenciales |
| `<details>` | un plan largo colapsado mantiene el PR legible |

**El rol `plan` se estrenó aquí** y funcionó a la primera, porque el prefijo del subject está
extraído a variable — justo la razón de haberlo hecho así. La condición `s3:prefix` que tenía
anotada como sospechosa tampoco dio problemas.

---
---

# Parte 4 — Catálogo de problemas

Índice rápido. El detalle, debajo.

| # | Síntoma | Causa raíz |
|---|---|---|
| 1 | El perfil no se ignora en CI, aunque todo "valida" | `default = "null"` con comillas |
| 2 | — (silencioso) | Un policy document compartido entre `plan` y `deploy` |
| 3 | — (aparecería al crear `envs/prod`) | Nombres de rol sin el entorno |
| 4 | `.terraform.lock.hcl` dentro del módulo | `terraform init` corrido dentro del módulo |
| 5 | `2 to destroy` inesperado | Renombré la etiqueta de un recurso |
| 6 | `description ... -> null` en el plan | Se me cayó un atributo al reescribir |
| 7 | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | **Immutable subject claims** |
| 8 | `InvalidClientTokenId` en local | SSO mal configurado (+ 3 hipótesis descartadas) |
| 9 | `Missing required argument` / `Unsupported argument` | Renombrar una variable toca 3 archivos |

---

### Problema 1 — `default = "null"` con comillas

**Síntoma:** el provider busca un perfil llamado `null`.
**Causa:** `"null"` es la cadena de texto, no el literal.
**Arreglo:** `default = null`, sin comillas.
**Lección:** ninguna herramienta estática lo detecta → 2.6 y 2.8.

### Problema 2 — Un policy document compartido entre los dos roles

**Síntoma:** ninguno. Falla en silencio, que es lo peligroso.

**Causa:** escribí un solo `data "aws_iam_policy_document" "state_access"` y se lo puse a `plan` y
a `deploy`. Como concedía `PutObject`/`DeleteObject` sobre `terraform.tfstate`, **el rol de sólo
lectura podía sobrescribir o borrar el state.** Eso anula la razón de existir de los dos roles: un
PR ya no "como mucho corre un plan", puede corromper el state.

**Arreglo:** dos documentos separados → tabla en 2.4.

**Lo que confunde:** `plan` **sí** necesita escribir, pero **sólo el `.tflock`**. Un permiso
legítimo y otro peligroso viven en la misma ruta, separados por el sufijo del nombre.

**La lección general:** reutilizar un policy document entre dos roles es cómodo, y es exactamente
cómo se pierde el mínimo privilegio sin darse cuenta. **Si dos roles existen porque deben poder
hacer cosas distintas, sus políticas no pueden ser el mismo objeto.**

### Problema 3 — Nombres de rol sin el entorno

**Síntoma:** ninguno todavía; aparecería como `EntityAlreadyExists` al crear `envs/prod`.
**Causa:** `taskflow-github-plan` en vez de `taskflow-dev-github-plan`.
**Arreglo:** variable `env` y `name = "taskflow-${var.env}-github-plan"`.

**Es la misma clase de bug** que evité poniendo el provider OIDC en bootstrap, aparecida por otro
lado: un recurso con identificador único a nivel cuenta, instanciado desde algo que se repite por
entorno. **Cuando un recurso de AWS tiene nombre único global, el entorno va en el nombre**, no
sólo en el directorio.

### Problema 4 — `.terraform.lock.hcl` dentro del módulo

**Causa:** corrí `terraform init` dentro del directorio del módulo.
**Arreglo:** borrarlo. Sólo los root modules tienen lock → 2.3.

### Problema 5 — `2 to destroy` inesperado

**Síntoma:** el plan quería destruir dos policies que yo creía estar conservando.
**Causa:** renombré las etiquetas (`plan_state` → `plan_state_access`).
**No era peligroso**, pero el reflejo correcto es leer el motivo → 2.2, y el bloque `moved`.

### Problema 6 — `description ... -> null`

**Síntoma:** el plan iba a borrar la descripción de los dos roles.
**Causa:** al reescribir el archivo se me cayó el atributo.
**Lección:** **en un plan, un `-> null` significa que borré algo del código sin querer.** Vale la
pena buscarlos antes de aprobar.

### Problema 7 — Immutable subject claims ⭐

**El hallazgo más importante del Bloque B.**

**Síntoma:** `Not authorized to perform sts:AssumeRoleWithWebIdentity`, genérico.

**Causa:** mi trust policy decía `repo:Arlosaid/taskflow:ref:refs/heads/main` y el claim real era
`repo:Arlosaid@99146811/taskflow@1316477490:ref:refs/heads/main` → ver 2.5.

**Cómo lo diagnostiqué** — el step que se pagó solo:

```yaml
- run: |
    curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
      | jq -r '.value' | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub,aud,ref,environment}'
```

Decodifica el payload del JWT (no verifica la firma, sólo mira). Sin él, el mensaje de STS no dice
*qué* no coincidió y se pueden perder horas. **Borrar el step después.**

**Detalle del log que vale recordar:** `configure-aws-credentials@v6` reintentó **12 veces** con
backoff exponencial durante 2m33s. Un `sub` que no coincide **no es un error transitorio** — la
respuesta iba a ser idéntica las 12 veces. La action no puede distinguir "AWS saturado" de "tu
política está mal". **12 reintentos con el mismo error = error determinista; no esperes, ve a leer
la política.**

### Problema 8 — `InvalidClientTokenId` en local

**Causa raíz real:** tenía **SSO a medio configurar**. Pero llegué ahí tras descartar tres
hipótesis, y las tres enseñan algo.

**Hipótesis A — variables de entorno con precedencia.** Ver 2.6. No era, pero es el primer sitio
donde mirar siempre.

**Hipótesis B — WSL tiene dos `$HOME`.** Mi `PATH` incluía
`/mnt/c/Program Files/Amazon/AWSCLIV2/`: el `aws` que ejecutaba era el **binario de Windows**,
leyendo `C:\Users\Alonso\.aws\`. Terraform es un binario de Linux y lee `/home/alonso/.aws/`.
**Dos archivos distintos con el mismo nombre de perfil.** Por eso `aws sts get-caller-identity`
funcionaba y `terraform plan` no.

→ **Regla adoptada: todo el flujo del proyecto vive del lado Linux.** AWS CLI, Terraform, git, el
repo en `~/projects` (nunca en `/mnt/c`, que además es lento). Para editar, la extensión WSL de
VS Code / Cursor abre la carpeta de Linux desde la interfaz de Windows.

**Hipótesis C — CRLF.** Al copiar el `credentials` de Windows, `cat -A` mostró `^M$` al final de
cada línea. Un `\r` pegado al valor convierte `AKIA...` en `AKIA...\r`, que AWS no reconoce.
`sed -i 's/\r$//' archivo` lo arregla; un heredoc (`cat > archivo <<'EOF'`) escribe siempre con LF.

Es exactamente el motivo por el que este proyecto se desarrolla en Linux: **el runner de CI es
`ubuntu-latest`**, y cuanto más se parezca mi máquina al runner, menos "en mi máquina sí funciona".

### Problema 9 — Renombrar una variable toca tres archivos

**Síntoma:** `Missing required argument: github_repository` y
`Unsupported argument: github_subject_prefix`, ambos apuntando a `envs/dev/main.tf`.

**Causa:** cambié el nombre en la llamada pero no en el `variables.tf` del módulo.

**Detalle a saber leer:** los dos errores apuntaban al **punto de llamada**, pero el archivo a
arreglar era el `variables.tf` **del módulo**. Terraform siempre reporta el desajuste donde se
llama, no donde falta la definición — como un error de firma de función.

**Los tres archivos cambian juntos:** la variable se **declara** en el módulo, se **usa** en el
módulo, y se **pasa** desde el entorno.

---

## Dos errores de método (no técnicos)

**Pegué una credencial real en un chat.** Corrí `cat -A ~/.aws/credentials` y su salida incluye el
`aws_secret_access_key` completo. Tuve que rotar la llave. **Nunca volcar un archivo de
credenciales sin filtrar:** `cat archivo | sed 's/=.*/= REDACTED/'`.

**Pegué marcadores de posición literalmente.** Ejecuté `export AWS_ACCESS_KEY_ID='AKIA...'` tal
cual, con los puntos suspensivos. El test no probó nada y encima dejó variables basura en el shell
que rompían los intentos siguientes. **Si un comando de depuración falla, verificar que lo que se
ejecutó era lo que se pretendía ejecutar** antes de sacar conclusiones.

---
---

# Parte 5 — Decisiones descartadas y riesgos aceptados

| Decisión | Por qué |
|---|---|
| **ADRs** | Proyecto personal de práctica; las decisiones viven en esta bitácora, que cumple la misma función sin la ceremonia |
| **DynamoDB para el lock** | El locking nativo de S3 (`use_lockfile`) es más simple |
| **CMK de KMS para el bucket de estado** | SSE-S3 es gratis y suficiente a esta escala |
| **`thumbprint_list` en el provider OIDC** | Ya no es un control de seguridad real |
| **Kubernetes** | `k8s/` existe de una idea inicial, pero el proyecto va a **ECS Fargate** — menos superficie operativa y más barato |
| **GitHub Environments** | Aplazados, no descartados. Un solo entorno por ahora; el trust policy ya los soporta |
| **NAT Gateway en dev** *(pendiente, Bloque D)* | ~$32/mes. Se usarán VPC endpoints |

**Riesgos aceptados que van al README:**
- Un solo entorno; **sin gate de aprobación manual** antes de desplegar.
- Las cuatro supresiones de checkov del bucket de estado (replicación cross-region, access
  logging, notificaciones de eventos, KMS).

---
---

# Parte 6 — Preguntas de entrevista

Las que **ya puedo responder con código detrás**:

**1. ¿Cómo se autentica tu pipeline con AWS?**
> GitHub Actions asume un rol de AWS por federación OIDC. No hay access keys en secretos del
> repositorio: el workflow presenta un token OIDC de corta vida, STS valida la firma contra el
> provider registrado y evalúa el trust policy del rol contra los claims del token, y obtengo
> credenciales temporales de una hora acotadas a ese repositorio y ese contexto. Nada que rotar,
> nada que filtrar.

**2. ¿Qué impide que un pull request despliegue a producción?**
> La condición `sub` del trust policy. Hay dos roles: los pull requests sólo pueden asumir uno de
> sólo lectura —puede leer el state y tomar el lock, pero no escribirlo— y el rol de deploy sólo
> acepta subjects de `main`. La condición usa `StringEquals` con el subject completo: un comodín
> como `repo:owner/repo:*` haría match con cualquier rama y convertiría la frontera en decoración.

**6. ¿Diferencia entre `terraform validate` y `checkov`?**
> `validate` mira sintaxis y tipos sin hacer llamadas a la nube; `checkov` busca misconfiguración
> de seguridad. Y añadiría que hay una clase de fallos que ninguno de los dos cubre: los que
> dependen del entorno de ejecución. Me pasó tres veces en este proyecto, y las tres con
> `validate` en verde.

**Pendientes de construir (Bloques C–E):** 3 (secretos en la task definition), 4 (migraciones y
expand/contract), 5 (rollback), 7 (CVE sin fix), 8 (por qué no `latest`).
