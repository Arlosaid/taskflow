# Bitácora de TaskFlow

Registro de **qué construí, por qué lo decidí así y qué aprendí**. Escrito para mi yo del futuro:
cuando el proyecto esté terminado y tenga que explicarlo, esto es lo que se me va a haber olvidado.

Una entrada por paso del [roadmap](./roadmap.md). Escríbela **en el momento**, no al final —
la razón de una decisión se olvida mucho antes que la decisión.

**Plantilla:**

```markdown
## [N] Título — fecha

**Qué hice:** una o dos frases.
**Por qué así:** la decisión y qué descarté.
**Concepto que aprendí:** lo que no sabía antes.
**Trampa:** lo que me costó tiempo o casi me sale mal.
```

---

## [0] El backend de estado — bootstrap

**Qué hice:** un bucket S3 para el state de Terraform, con versioning, cifrado SSE-S3,
public access block completo, lifecycle de 90 días para versiones antiguas, y
`prevent_destroy = true`.

**Por qué así:**
- **Backend local en bootstrap, a propósito.** Es la raíz del huevo-y-gallina: este módulo crea
  el bucket donde los demás guardan su estado, así que no puede guardar el suyo ahí. Es uno de
  los dos `terraform apply` manuales legítimos del proyecto.
- **SSE-S3 (AES256) en vez de una llave KMS propia.** Es gratis; un CMK añade costo y gestión de
  llaves sin beneficio real a esta escala.
- **`use_lockfile = true` en vez de tabla DynamoDB.** El locking nativo de S3 evita mantener una
  tabla extra sólo para el lock. Es más nuevo y más simple.
- **Versioning encendido** = botón de deshacer si un apply corrompe el estado.

**Concepto:** el state contiene IDs, ARNs y a veces valores sensibles. Ese bucket nunca puede
ser público, bajo ninguna circunstancia — de ahí los cuatro flags del `public_access_block`.

**Sobre las supresiones de checkov:** las cuatro que hay en `main.tf` llevan razón escrita.
Un revisor confía más en una supresión justificada que en un reporte limpio. Lo que **no** se
vale es suprimir sin explicar.

---

## [1] Unificar las versiones del provider

**Qué hice:** `~> 6.0` y `required_version >= 1.11` en bootstrap, en `envs/dev` y en los módulos.

**Por qué:** bootstrap estaba en `~> 5.60` y dev en `~> 6.0`. Dos providers distintos en el mismo
repo producen comportamientos distintos ante el mismo HCL, y es el tipo de inconsistencia que un
revisor nota inmediatamente.

**Concepto:** son dos cosas diferentes.
- `required_version` → la versión del **binario** de Terraform.
- `required_providers` → la versión del **plugin** del proveedor (AWS).
- `.terraform.lock.hcl` → fija los hashes exactos de los plugins. **Se commitea**, igual que un
  `package-lock.json`. Es lo que hace que CI y tu laptop resuelvan exactamente lo mismo.

---

## [5.6] `aws_profile` opcional para que dev sirva en local y en CI

**Qué hice:** cambié el `default` de `var.aws_profile` de `"taskflow-dev"` a `null`.

**Por qué:** en mi máquina el provider debe usar el perfil `taskflow-dev` de
`~/.aws/credentials`. En GitHub Actions no hay ningún perfil — `configure-aws-credentials`
exporta las credenciales temporales como **variables de entorno**. Con un `profile` fijo, el
provider ignora esas variables, busca un archivo que en el runner no existe, y falla.

**Concepto:** el provider de AWS trata `null` como *"este argumento no fue especificado"* y cae a
la **cadena estándar de credenciales**: variables de entorno → perfil → metadata de la
instancia. Es el patrón general para hacer opcional cualquier argumento de un provider.

**Trampa (me pasó):** `null` va **sin comillas**. Escribí `default = "null"` y eso es la cadena
de texto `null` — el provider se pone a buscar un perfil llamado literalmente "null". Las tres
variantes son distintas y sólo una sirve:

| Valor | Qué hace |
|---|---|
| `null` | ✅ argumento no especificado → cadena estándar de credenciales |
| `"null"` | ❌ busca un perfil llamado `null` |
| `""` | ❌ busca un perfil con nombre vacío |

**Trampa #2, la más importante que aprendí aquí:** **ninguna** de mis herramientas detecta este
error. `terraform validate` lo da por bueno (es un string válido en un argumento que espera
string), `fmt` sólo mira formato, `tflint` no puede saber qué perfiles existen en otra máquina,
y `checkov` busca problemas de seguridad, no de portabilidad. No es un error de código: es un
error de **entorno**. El código es correcto en mi laptop e incorrecto en el runner.

Por eso el smoke test del paso 5.8 no es opcional — es la única verificación que realmente
prueba esto.

**En local ahora hay que exportar la variable:** `export TF_VAR_aws_profile=taskflow-dev`
(Terraform lee automáticamente cualquier `TF_VAR_<nombre>`). No puedo commitear un `.tfvars`
con eso porque `.gitignore` bloquea `*.tfvars`, y está bien que lo haga.

---

## [5.1 / 5.2] El provider OIDC vive en bootstrap

**Qué hice:** `aws_iam_openid_connect_provider` para `token.actions.githubusercontent.com` en
`infra/bootstrap/main.tf`, con su output.

**Por qué ahí y no en `envs/dev`:** es un recurso **de cuenta, único** — sólo puede existir uno
por URL en toda la cuenta AWS. Si lo pongo en `envs/dev`, el día que cree `envs/prod` el segundo
`apply` explota con `EntityAlreadyExists` y hay que arreglarlo con `terraform import`.

**Concepto — la regla más importante de organización en Terraform:** *un objeto de AWS debe
estar en un solo state.* Si dos states creen que gestionan el mismo recurso se pisan. De ahí la
jerarquía que quedó:

- **bootstrap** = cosas de cuenta, únicas, casi inmutables (bucket de estado, provider OIDC)
- **envs/** = cosas por entorno, que se crean y se destruyen (roles, VPC, ECS)

**Sobre `thumbprint_list`:** lo omití. Es opcional en el provider AWS v5+; desde 2023 AWS valida
el certificado de GitHub contra sus CAs raíz de confianza, así que ese hash largo que sale en
todos los blogs ya no es un control de seguridad real — es un vestigio.

---

## [5.3] Qué es un módulo de Terraform

**Concepto:** un módulo es una **función**. Entra por `variables`, sale por `outputs`, y lo de
dentro es privado.

Por eso **nunca lleva bloque `provider` ni `backend`** — eso es responsabilidad de quien lo
llama. Si metes un `provider` dentro, el módulo queda atado a una región y unas credenciales
concretas, deja de ser reutilizable, y Terraform te bloquea usar `for_each` sobre él.

El `versions.tf` de un módulo declara qué provider **necesita** (`required_providers`), no cuál
usa. Es una restricción, no una instanciación.

---

## [5.4 / 5.5] OIDC: cómo funciona y dónde está la seguridad

### El flujo completo

1. El job arranca. GitHub le inyecta `ACTIONS_ID_TOKEN_REQUEST_URL` y
   `ACTIONS_ID_TOKEN_REQUEST_TOKEN`. El job pide un token a ese endpoint.
2. GitHub emite un **JWT firmado** con claims que dicen quién es ese workflow: `iss`, `aud`,
   `sub`, `repository`, `ref`, `environment`. Vale pocos minutos.
3. `configure-aws-credentials` llama a **`sts:AssumeRoleWithWebIdentity`** con ese JWT.
4. STS descarga las claves públicas de GitHub — sabe dónde buscarlas gracias al
   `aws_iam_openid_connect_provider` que registré —, **verifica la firma**, y evalúa el **trust
   policy** del rol contra los claims.
5. Si pasa, devuelve credenciales temporales de 1 hora.

**Lo que yo construyo en Terraform son sólo los pasos 3 y 4: el ancla de confianza y las reglas.**

**La frase para explicarlo:** no hay llaves guardadas porque la identidad no es un secreto
compartido, es una firma criptográfica que se verifica en cada ejecución. Nada que rotar, nada
que filtrar.

### La distinción de IAM que más se confunde

Hay **dos políticas por rol** y hacen cosas completamente distintas:

| | Dónde va | Responde a |
|---|---|---|
| **Trust policy** | `assume_role_policy` del rol | **¿QUIÉN puede convertirse en este rol?** |
| **Permission policy** | attachment o `aws_iam_role_policy` | **¿QUÉ puede hacer una vez que ya lo es?** |

OIDC vive enteramente en el **trust policy**. El permission policy ni se entera de que GitHub
existe.

### Las dos condiciones del trust policy

- **`aud = sts.amazonaws.com`** → "este token fue emitido *para* STS". Protege contra reutilizar
  un token que GitHub emitió para otro servicio.
- **`sub`** → "viene de *este* repo, en *esta* circunstancia". **Es la frontera de seguridad
  real.**

### ⚠️ Immutable subject claims — mi repo NO usa el formato clásico

**El hallazgo más importante de todo el paso 5.** Mi repositorio usa el formato nuevo de
**immutable subject claims** de GitHub, que incorpora el **ID numérico del propietario** y el
**ID del repositorio**:

```
repo:OWNER@OWNER-ID/REPO@REPO-ID:<contexto>
```

en vez del clásico `repo:OWNER/REPO:<contexto>`. GitHub aplica este formato por defecto a los
repositorios creados **después del 15 de julio de 2026**.

**Por qué existe:** el nombre de un repo o de una organización se puede **renombrar**, y alguien
puede registrar después el nombre que tú dejaste libre. Un trust policy anclado a
`repo:Arlosaid/taskflow` seguiría al nombre, no a mi repositorio. Los IDs numéricos son
inmutables: identifican **este** repo para siempre, sobreviven a renombrados y no se pueden
reclamar. Es una mejora real de seguridad.

**La consecuencia práctica, y es brutal:** una condición construida con el nombre plano
(`repo:Arlosaid/taskflow:pull_request`) **nunca hace match**. Y no falla de forma ruidosa ni
descriptiva — sale un `Not authorized to perform sts:AssumeRoleWithWebIdentity` genérico, el
mismo que sale por cualquier otro error de `sub`. Todos los tutoriales y ejemplos que hay online
son del formato viejo.

**La lección que generalizo:** nunca ensamblar el `sub` a mano a partir del nombre del repo.
**Sacar el literal del token decodificado** y usar ése. El token es la única fuente de verdad;
la documentación y los blogs envejecen.

**Lo confirmé en carne propia.** El smoke test falló con `Not authorized to perform
sts:AssumeRoleWithWebIdentity` y el step que decodifica el JWT me dio el literal:

```json
"sub": "repo:Arlosaid@99146811/taskflow@1316477490:ref:refs/heads/main"
"aud": "sts.amazonaws.com"
"repository_owner_id": "99146811"
"repository_id": "1316477490"
```

Mi trust policy decía `repo:Arlosaid/taskflow:ref:refs/heads/main`. El `aud` estaba bien; el
`sub` era el único problema. Mi prefijo real es:

```
repo:Arlosaid@99146811/taskflow@1316477490
```

```bash
# Los IDs también se pueden consultar por API:
curl -s https://api.github.com/repos/Arlosaid/taskflow | jq '{owner_id: .owner.id, repo_id: .id}'
```

**El step de depuración se pagó solo.** Sin él, el mensaje de STS es genérico y no dice *qué*
no coincidió. Con él, el diagnóstico fue inmediato. Merece la pena tenerlo a mano para cualquier
problema futuro de OIDC.

**Detalle del log que vale la pena recordar:** `configure-aws-credentials@v6` reintentó 12 veces
con backoff exponencial durante 2m33s. Un `sub` que no coincide **no es un error transitorio** —
la respuesta iba a ser idéntica las 12 veces. La action no puede distinguir "AWS saturado" de
"tu política está mal", así que reintenta todo. **12 reintentos con el mismo error = error
determinista; no esperes, ve a leer la política.**

**Cómo lo dejé en el módulo:** en vez de construir el prefijo desde `github_repository`, lo paso
como variable con el literal ya resuelto, para que el código documente la trampa:

```hcl
variable "github_subject_prefix" {
  description = "Immutable subject prefix taken verbatim from a decoded OIDC token, e.g. repo:owner@123/repo@456. Do NOT assemble this from the repo name: this repo uses immutable subject claims and the plain owner/repo form never matches."
  type        = string
}
```

Y las condiciones quedan `"${var.github_subject_prefix}:pull_request"`, etc.

### La forma del claim `sub` — la tabla a memorizar

| Cómo dispara el job | `sub` que emite GitHub |
|---|---|
| `on: pull_request` | `repo:ORG/REPO:pull_request` |
| `on: push` a main, job **sin** `environment:` | `repo:ORG/REPO:ref:refs/heads/main` |
| job **con** `environment: prod` | `repo:ORG/REPO:environment:prod` |
| tag | `repo:ORG/REPO:ref:refs/tags/v1.0.0` |

**La trampa:** en cuanto un job declara `environment:`, el `sub` toma la forma `environment:` y
**la rama desaparece del claim**. No es "main *y además* prod" — es sólo lo segundo. Por eso el
rol de deploy lleva las tres variantes en sus `values`.

### El error que hay que saber nombrar

`repo:Arlosaid/taskflow:*` parece inofensivo y no lo es: hace match con **cualquier** rama.
Cualquiera que consiga pushear una rama al repo puede asumir el rol de despliegue a producción.
El comodín convierte una frontera de seguridad en decoración. Por eso uso `StringEquals` y no
`StringLike` — sin comodines que necesitar, `StringEquals` no puede degradarse por accidente.

### Dos roles, no uno

- **`plan`** — sólo lectura, asumible desde pull requests. Un PR malicioso, como mucho, corre un plan.
- **`deploy`** — permisos de apply, asumible sólo desde `main` / los Environments.

Sobre forks: GitHub restringe fuertemente los permisos del token en PRs desde forks, así que en
la práctica un fork no obtiene el token OIDC. Pero **no dependo de eso** — el rol de plan es de
sólo lectura de todas formas. Dos capas, no una.

### Detalles de permisos que aprendí

- **`data "aws_iam_policy_document"` no llama a AWS.** Sólo renderiza JSON. Se usa en vez de
  `jsonencode` porque da validación en `terraform validate` y un diff legible en el plan.
- **Attachment vs inline:** `aws_iam_role_policy_attachment` conecta una política que existe por
  separado y es compartible (como la managed `ReadOnlyAccess`); `aws_iam_role_policy` es inline,
  pertenece al rol y muere con él. Usé inline para el acceso al state porque es específica de
  ese rol y nadie más debería tenerla.
- **Un rol "de sólo lectura" necesita `PutObject`.** Con `use_lockfile = true`, `terraform plan`
  crea un objeto `.tflock` en S3 para adquirir el lock y lo borra al terminar. Sin ese permiso el
  plan muere antes de empezar. Está acotado a *exactamente* esa clave, no al bucket entero.
- **`max_session_duration = 3600`** → las credenciales caducan en 1 hora. Cuanto más corta la
  sesión, menor la ventana si algo se filtra.
- **El rol de deploy nace casi sin permisos.** Todavía no hay nada que desplegar. Crecen servicio
  por servicio en el Bloque D. Una política ancha "temporal" nunca se cierra.
- Cuando llegue a necesitar permisos de IAM (para crear los roles de ECS), hay que acotarlos a
  nombres `taskflow-*` y exigir un **permissions boundary**. Si no, el rol de deploy puede crear
  un rol admin y escalar privilegios.

---

## [5.7] Por qué `data` en vez de ARNs hardcodeados

En `envs/dev` busco el provider OIDC con un `data "aws_iam_openid_connect_provider"` en vez de
pegar el ARN como string. Ventajas: no necesito saber mi account ID, funciona igual en otra
cuenta, y si el provider no existe **Terraform falla claramente en el plan** en vez de crear un
rol roto que descubro tres días después.

**Concepto — `data` vs `resource`:**
- `resource` = Terraform **gestiona el ciclo de vida** (crea, modifica, destruye).
- `data` = Terraform sólo **lee** algo que ya existe. Nunca lo toca.

El provider OIDC es un `resource` en bootstrap y un `data` en dev: el mismo objeto de AWS,
bootstrap lo posee, dev sólo lo consulta.

La alternativa "de libro" sería `terraform_remote_state` para leer los outputs de bootstrap,
pero bootstrap usa backend local — no hay state remoto que leer. El data lookup lo resuelve
mejor.

**Este apply es manual y está bien.** CI no puede crear el rol que CI necesita para
autenticarse. Junto con bootstrap, es el último `terraform apply` manual legítimo del proyecto.

---

## [5.3–5.7] Escribiendo el módulo: dos errores que cometí

**Qué hice:** el módulo completo — dos trust policies, dos roles, `ReadOnlyAccess` en el de plan,
acceso al state, outputs — y lo consumí desde `envs/dev` con data lookups.

**Decisiones propias que tomé y mantengo:**
- `github_repository` como una sola variable `"owner/name"` en vez de `github_org` +
  `github_repo`. Menos superficie y el claim `sub` se construye igual.
- `state_key_prefix` como variable (`"dev/"`) en vez de derivarlo de `env`. Más explícito.
- Condición `s3:prefix` sobre el `ListBucket`, acotándolo a `dev/*` en vez de al bucket entero.
  Estrictamente más restrictivo de lo que necesitaba.

### Error 1 — compartí el mismo policy document entre los dos roles

Escribí un solo `data "aws_iam_policy_document" "state_access"` y se lo puse a `plan` y a
`deploy`. Como ese documento concede `PutObject` y `DeleteObject` sobre
`dev/terraform.tfstate`, **el rol de sólo lectura podía sobrescribir o borrar el state.**

Eso anula la razón de existir de los dos roles. Un PR ya no "como mucho corre un plan": puede
corromper el state, y entonces Terraform pierde el mapa de lo que existe y el siguiente apply
intenta recrearlo todo.

**Lo que confunde:** `plan` **sí** necesita escribir — pero **sólo el objeto `.tflock`**, nunca
el state. Un permiso legítimo y otro peligroso viven en la misma ruta, separados por el sufijo
del nombre. Van en documentos separados:

- `plan` → `GetObject` sobre `terraform.tfstate` + `PutObject`/`DeleteObject` **sólo** sobre
  `terraform.tfstate.tflock`
- `deploy` → `GetObject`/`PutObject`/`DeleteObject` sobre ambos

**La lección general:** reutilizar un policy document entre dos roles es cómodo, y es
exactamente cómo se pierde el mínimo privilegio sin darse cuenta. Si dos roles existen porque
deben poder hacer cosas distintas, sus políticas **no pueden ser el mismo objeto**.

### Error 2 — los nombres de rol sin el entorno

Puse `taskflow-github-plan` en vez de `taskflow-dev-github-plan`.

**Los nombres de rol de IAM son globales por cuenta.** Cuando exista `envs/prod` en la misma
cuenta e instancie este módulo otra vez, el apply muere con `EntityAlreadyExists`.

Es **la misma clase de bug** que evité poniendo el provider OIDC en bootstrap, aparecida por
otro lado: un recurso con identificador único a nivel cuenta, instanciado desde algo que se
repite por entorno. Cuando un recurso de AWS tiene un nombre único global, el entorno tiene que
ir **en el nombre**, no sólo en el directorio.

### Error 3 — `.terraform.lock.hcl` dentro del módulo

Se me coló porque corrí `terraform init` dentro del directorio del módulo. Los módulos **no son
root modules**: no tienen backend propio ni lock propio. El lock que manda es el de
`infra/envs/dev/`. Borrado.

---

## [5.7] El apply, y lo que aprendí leyendo el plan

**Qué hice:** apliqué el módulo a mano desde `infra/envs/dev` con mi perfil local. Quedaron
creados `taskflow-dev-github-plan` y `taskflow-dev-github-deploy` con sus políticas.

### Renombrar un recurso = destruirlo y crearlo

Al separar el policy document cambié las etiquetas de los recursos (`plan_state` →
`plan_state_access`). El plan me mostró **2 to destroy**, y me asusté antes de leer el motivo:

```
# (because aws_iam_role_policy.deploy_state is not in configuration)
```

**Concepto:** Terraform identifica los recursos por su **dirección** (`aws_iam_role_policy.plan_state`),
no por el nombre que tienen en AWS. Si cambio la etiqueta, para él el viejo desapareció de la
configuración y hay uno nuevo. Destruir + crear.

En una policy inline da igual, se recrea en milisegundos. **En una base de datos o un bucket,
eso borra el recurso.** Para esos casos existe el bloque `moved`:

```hcl
moved {
  from = aws_iam_role_policy.plan_state
  to   = aws_iam_role_policy.plan_state_access
}
```

Le dice "es el mismo objeto, sólo cambió de nombre" y el plan pasa a no mostrar cambios.
Aquí no valía la pena, pero es la herramienta para el día que renombre algo con datos dentro.

**Regla que me llevo: leer siempre el motivo del destroy antes de aprobar un plan.** "2 to
destroy" no dice nada por sí solo; el comentario de arriba sí.

### El `description` que se me cayó

Al reescribir el archivo se me perdieron los `description` de los dos roles y el plan iba a
borrarlos (`-> null`). No rompe nada, pero es lo único que distingue un rol de otro cuando los
veo listados en la consola de IAM meses después. Los repuse antes de aplicar.

**Recordatorio:** en un plan, un `-> null` significa que borré algo del código sin querer.
Vale la pena buscarlos.

### El resultado, que es la respuesta a una pregunta de entrevista

| | `s3:GetObject` state | `s3:PutObject` state | `s3:PutObject` tflock |
|---|---|---|---|
| `plan` | ✅ | ❌ | ✅ |
| `deploy` | ✅ | ✅ | ✅ |

Esa tabla **es** la respuesta a *"¿qué impide que un pull request corrompa tu infraestructura?"*.
El rol de plan puede leer el estado y tomar el lock, y nada más. No puede sobrescribirlo.

### Pendiente de vigilar

La condición `"s3:prefix" = "dev/*"` sobre el `ListBucket`: con `StringLike`, una llamada a
`ListBucket` **sin** parámetro de prefijo no hace match y devuelve `AccessDenied`. Con un backend
S3 de key fija no debería ocurrir, pero si en CI aparece un `AccessDenied` sobre `ListBucket`,
ése es el primer sospechoso.

---

## [5.8] El smoke test, y una tarde entera perdida en credenciales locales

**Qué hice:** un workflow desechable con `workflow_dispatch` que sólo asume el rol y corre
`aws sts get-caller-identity`. Salida final:

```
arn:aws:sts::654740195516:assumed-role/taskflow-dev-github-deploy/...
```

`assumed-role` y `arn:aws:sts::` (no `iam::`) = credenciales temporales obtenidas por federación.
Cero secretos en el repositorio. **La federación OIDC funciona de punta a punta.**

**Por qué probé el rol `deploy` y no el de `plan`:** un `workflow_dispatch` en main emite
`sub = ...:ref:refs/heads/main`, que coincide con deploy. El de plan sólo acepta `:pull_request`
y no se puede ejercitar desde aquí — se estrena con el PR real del paso 7.

### El problema que me costó la tarde: `InvalidClientTokenId` en local

Después de arreglar el `sub`, `terraform plan` dejó de funcionar **en mi máquina**. La causa
real: **tenía SSO a medio configurar**. Pero llegué ahí después de descartar tres hipótesis, y
las tres enseñan algo.

**Lo primero que hay que saber leer — qué significa cada error de credenciales:**

| Error | Significa |
|---|---|
| `InvalidClientTokenId` | Se encontraron credenciales, **AWS no reconoce la access key** |
| `SignatureDoesNotMatch` | La key existe, **el secreto está mal** |
| `no valid credential sources` | **No se encontró ninguna** credencial |
| `ExpiredToken` | Credenciales temporales **caducadas** |

Distinguirlas ahorra horas. Yo estuve buscando "no hay credenciales" cuando el error decía
claramente "hay, pero no las reconozco".

### Lección 1 — las variables de entorno ganan al perfil

En la cadena estándar de credenciales, **las variables de entorno van primero**, antes que el
perfil del archivo. Un `AWS_ACCESS_KEY_ID` viejo exportado en el shell rompe todo aunque el
provider tenga `profile = "taskflow-dev"` bien puesto.

Es **el mismo mecanismo** que hace funcionar OIDC en CI (paso 5.6): allí juega a favor, aquí en
contra. Primer sitio donde mirar ante cualquier problema de credenciales: `env | grep -i AWS`.

### Lección 2 — WSL tiene dos `$HOME`, y yo estaba a caballo

Mi `PATH` tenía `/mnt/c/Program Files/Amazon/AWSCLIV2/`: el `aws` que ejecutaba era **el binario
de Windows**, leyendo `C:\Users\Alonso\.aws\`. Terraform es un binario de Linux y lee
`/home/alonso/.aws/`. **Dos archivos distintos con el mismo nombre de perfil.**

Por eso `aws sts get-caller-identity --profile taskflow-dev` funcionaba y `terraform plan` no.

La regla que adopto: **todo el flujo del proyecto vive del lado Linux.** AWS CLI, Terraform, git,
el repo en `~/projects` (nunca en `/mnt/c`, que además es lento). Para editar, la extensión WSL
de VS Code / Cursor abre la carpeta de Linux desde la interfaz de Windows.

### Lección 3 — CRLF corrompe archivos de configuración

Al copiar el `credentials` de Windows, `cat -A` mostró `^M$` al final de cada línea. Un `\r`
pegado al valor convierte `AKIA...` en `AKIA...\r`, que AWS no reconoce → `InvalidClientTokenId`.

No era mi causa raíz, pero es real y encaja con el mismo síntoma. `sed -i 's/\r$//' archivo` lo
arregla, y un heredoc (`cat > archivo <<'EOF'`) escribe siempre con LF.

Es exactamente el motivo por el que este proyecto se desarrolla en Linux: el runner de CI es
`ubuntu-latest`, y cuanto más se parezca mi máquina al runner, menos "en mi máquina sí funciona".

### Dos errores de método que cometí

**Pegué una credencial real en un chat.** Corrí `cat -A ~/.aws/credentials` y su salida incluye
el `aws_secret_access_key` completo. Tuve que rotar la llave. **Nunca volcar un archivo de
credenciales sin filtrar**: `cat archivo | sed 's/=.*/= REDACTED/'`.

**Pegué los marcadores de posición literalmente.** Ejecuté `export AWS_ACCESS_KEY_ID='AKIA...'`
tal cual, con los puntos suspensivos. El test no probó nada y encima dejó variables basura en el
shell que rompían los intentos siguientes. Si un comando de depuración falla, **verificar que lo
que se ejecutó era lo que se pretendía ejecutar** antes de sacar conclusiones.

### Lo que me llevo

Tres problemas seguidos en el paso 5 —el `profile` fijo, el `sub` con immutable claims, y este—
y **ninguno era un error de código**. `terraform validate` dio verde en los tres. La lección de
5.6 se confirmó a lo grande: existe una clase entera de fallos que ninguna herramienta estática
detecta, porque dependen de *dónde* se ejecuta el código, no de qué dice.

---

## Referencia — qué detecta cada herramienta

Los cuatro linters se solapan menos de lo que parece. Saber la diferencia es una pregunta
frecuente de entrevista.

| Herramienta | Detecta | Ejemplo |
|---|---|---|
| `terraform fmt` | sólo formato | indentación inconsistente |
| `terraform validate` | sintaxis y tipos, **sin llamadas a la nube** | variable no declarada, tipo de atributo equivocado |
| `tflint` | corrección específica del provider | tipo de instancia inválido, argumento deprecado |
| `checkov` / `tfsec` | **misconfiguración de seguridad** | bucket sin cifrado, SG abierto a `0.0.0.0/0`, RDS sin cifrar |
| `trivy` (imagen) | CVEs en paquetes del SO y dependencias | `libssl` vulnerable en la imagen base |
| `gitleaks` | credenciales commiteadas | una llave de AWS en un notebook |
| `pip-audit` | dependencias de Python vulnerables | CVE conocido en una librería fijada |

**Y la lección de [5.6]:** hay una clase entera de fallos que **ninguna** de ellas cubre — los
que dependen del entorno de ejecución. Sólo aparecen cuando el código corre en un contexto
distinto al tuyo.

---

## Cosas que decidí NO hacer (y por qué)

- **ADRs.** El plan original los recomendaba. Es un proyecto personal de práctica; las decisiones
  viven en esta bitácora, que cumple la misma función sin la ceremonia.
- **DynamoDB para el lock del state.** El locking nativo de S3 (`use_lockfile`) es más simple.
- **CMK de KMS para el bucket de estado.** SSE-S3 es gratis y suficiente a esta escala.
- **`thumbprint_list` en el provider OIDC.** Ya no es un control de seguridad real.
- **Kubernetes.** El directorio `k8s/` existe de una idea inicial, pero el proyecto va a ECS
  Fargate — menos superficie operativa y más barato para un portafolio.
