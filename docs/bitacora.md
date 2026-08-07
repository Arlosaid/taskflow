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

Cerrado el **Bloque B** (identidad federada + pipeline de pull request) y arrancado el **Bloque C**:
ya hay aplicación. La API responde `/healthz` y `/readyz`, corre en un contenedor no-root, y
levanta junto a Postgres con `docker compose`. No existe todavía infraestructura de carga en AWS
ni ningún endpoint de negocio.

```
taskflow/
├── .github/workflows/
│   └── pr.yml                    # lint + terraform plan comentado en cada PR
│
├── app/                          # la API
│   ├── config.py                 # pydantic-settings; ruta del .env absoluta → Problema 11
│   ├── db.py                     # engine de SQLAlchemy con pool_pre_ping
│   └── main.py                   # /healthz (liveness) y /readyz (readiness)
│
├── Dockerfile                    # multi-etapa, usuario no-root, HEALTHCHECK → 2.9
├── docker-compose.yml            # api + postgres con condition: service_healthy → 2.10
├── .dockerignore                 # mantiene el .env y el .git fuera de la imagen
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
├── makefile                      # atajos locales. CI NO lo usa, a propósito → ver [3]
├── pyproject.toml                # dependencias reales + pytest + ruff → ver [8]
├── uv.lock                       # versiones congeladas, commiteado igual que un lock de Terraform
├── CLAUDE.md                     # contexto del repo para sesiones de IA
└── docs/
    ├── roadmap.md                # el plan por bloques, con casillas
    ├── architecture.drawio       # el plano de datos, editable en diagrams.net
    └── bitacora.md               # este archivo
```

Vacíos a propósito por ahora: `worker/` (llega en el Bloque F) y `k8s/` (fuera de alcance).

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

## 2.9 · Docker — imágenes, capas y contenedores

Escrito desde cero, porque es la pieza que más se usa a diario y la que más se aprende de memoria
sin entenderla.

### El modelo mental: tres cosas distintas

| Cosa | Qué es |
|---|---|
| **Dockerfile** | la receta. Texto, versionado en el repo |
| **Imagen** | el resultado de ejecutar la receta. Inmutable, de sólo lectura, **apilada en capas** |
| **Contenedor** | una imagen en ejecución, con una capa escribible encima. Se crea y se destruye sin tocar la imagen |

La imagen es la clase; el contenedor, la instancia. De la misma imagen salen veinte contenedores
idénticos, y eso es exactamente lo que hace ECS cuando corre dos tasks.

**Contenedor vs máquina virtual** — la comparación que piden en entrevista: una VM virtualiza
*hardware*, así que lleva su propio kernel y un SO completo; arranca en minutos y pesa gigas. Un
contenedor **comparte el kernel del host** y sólo lleva el sistema de archivos de usuario;
arranca en milisegundos. Por eso una imagen de Debian pesa 80 MB y no 2 GB: no incluye kernel.

La consecuencia práctica: un contenedor Linux **no corre sobre un kernel Windows**. Docker
Desktop en Windows levanta una VM Linux por debajo — de ahí que este proyecto viva en WSL.

### Las capas, y por qué el orden de las líneas decide el tiempo de build

Cada instrucción que toca el sistema de archivos (`COPY`, `RUN`, `ADD`) crea una **capa**, que es
un diff contra la anterior. La imagen es la pila.

Docker cachea capas: si la instrucción y sus entradas no cambiaron, la reusa. **Pero cuando una
capa se invalida, todas las de abajo también.** De ahí la regla más importante de un Dockerfile:

> Copia primero lo que cambia poco; al final, lo que cambia mucho.

Las dependencias cambian una vez al mes; el código, veinte veces al día. Por eso el orden es:

```dockerfile
COPY pyproject.toml uv.lock ./       # cambia poco
RUN uv sync --frozen --no-dev        # ← capa cara. Se reusa mientras el lock no cambie
COPY app ./app                       # cambia mucho
```

Al revés — `COPY . .` y después instalar — **cada línea de Python que toques reinstala todas las
dependencias**. La palabra para explicarlo es *invalidación de caché*.

### El build context, y qué protege de verdad `.dockerignore`

Cuando corres `docker build .`, ese punto no es decorativo: Docker **empaqueta ese árbol entero y
lo envía al motor** antes de leer la primera línea del Dockerfile. Eso es el *build context*.

`.dockerignore` decide qué no entra en ese paquete. Sirve para tres cosas, en este orden:

1. **Seguridad.** Sin él, un `COPY . .` mete el `.env`, las llaves y el `.git` completo dentro de
   la imagen. Y un secreto dentro de una capa **sigue en el registry aunque lo borres en una capa
   posterior**: las capas anteriores siguen ahí y se extraen con un comando.
2. **Velocidad.** Un `.venv` de 300 MB viajando al daemon en cada build.
3. **Caché.** `__pycache__` y `.pytest_cache` cambian constantemente e invalidan capas sin motivo.

### Multi-stage: por qué dos `FROM`

Para *construir* dependencias hacen falta herramientas (compiladores, headers, `uv`). Para
*ejecutar*, no. Un build multi-etapa usa una imagen con todo el herramental y copia sólo el
resultado a una imagen limpia.

Dos beneficios, y el segundo es de seguridad:

- la imagen final pesa menos — menos que bajar en cada deploy y menos superficie que escanear;
- **menos superficie de ataque**: un compilador dentro de un contenedor en producción es una
  herramienta lista para quien consiga ejecución.

### La imagen base: el tag es un blanco móvil

`python:3.12-slim` **no identifica una versión**. Es un puntero que el equipo de Docker mueve
cuando les da la gana. Pasó en este proyecto: el builder (`uv:python3.12-bookworm-slim`) trae
Debian **bookworm** con Python 3.12.12, y `python:3.12-slim` ya apunta a Debian **trixie** con
Python 3.12.13. Dos sistemas operativos distintos en el mismo Dockerfile, sin haberlo pedido.

Hoy funciona por casualidad: glibc es compatible hacia adelante, así que una rueda compilada en
bookworm corre en trixie. **Al revés reventaría**, y el día que el tag se mueva otra vez la
lotería puede salir al revés. La disciplina es la misma que con `required_version` de Terraform:
fijar la base explícitamente (`python:3.12-slim-bookworm`) para que las dos etapas sean el mismo
sistema.

### Usuario no-root

Por defecto un contenedor corre como root. No es el root del host, pero sí es root **dentro** del
contenedor: puede escribir cualquier archivo de la imagen e instalar lo que quiera, y si aparece
una fuga del aislamiento el impacto es mucho mayor. Crear un usuario de sistema y poner `USER`
antes del `CMD` cuesta dos líneas y es lo primero que mira un revisor.

### `CMD` vs `ENTRYPOINT`, y por qué la forma de lista no es opcional

`ENTRYPOINT` es el ejecutable; `CMD` son los argumentos por defecto y lo que se sobreescribe fácil
al correr la imagen.

Lo que de verdad importa: **usa siempre la forma de lista** (`["uvicorn", "app.main:app"]`), nunca
la de cadena. La forma de cadena arranca un `/bin/sh -c` que se queda como PID 1 y **se traga las
señales**: `docker stop` manda `SIGTERM`, el shell no lo propaga, y a los diez segundos Docker
mata el proceso a la fuerza. El resultado son cierres sucios y peticiones cortadas a media
respuesta — justo lo que no quieres durante un rolling deploy en ECS. Con la forma de lista,
uvicorn es PID 1 y recibe la señal directo.

### Detalles pequeños que se malentienden

| Instrucción | Qué hace en realidad |
|---|---|
| `EXPOSE 8000` | **nada funcional**: es metadato/documentación. Publicar el puerto es `-p` o `ports:` |
| `PYTHONUNBUFFERED=1` | Python deja de bufferizar stdout → los logs salen al instante. Sin esto salen a trozos, o se pierden si el contenedor muere |
| `WORKDIR /app` | crea el directorio y entra. Un `RUN cd` no sirve: cada `RUN` es un shell nuevo |
| `--chown` en `COPY` | evita un `RUN chown -R` posterior, que duplicaría todos los archivos en una capa nueva |

### Los comandos que hay que tener en los dedos

```bash
docker build -t taskflow-api .                 # construir
docker run --rm -p 8000:8000 taskflow-api      # correr y borrar al salir
docker ps                                       # qué está corriendo
docker logs -f <contenedor>                     # seguir los logs
docker exec -it <contenedor> sh                 # entrar a mirar
docker inspect --format='{{.State.Health.Status}}' <contenedor>
docker history taskflow-api                     # ← el que más enseña
```

`docker history` muestra qué línea del Dockerfile costó cuántos MB. Es la herramienta para
responder "¿por qué pesa 300 MB mi imagen?".

## 2.10 · docker compose — el entorno local completo

### DNS por nombre de servicio: la confusión número uno

Compose crea una red propia y **cada servicio es resoluble por su nombre**. Por eso la URL de la
base *dentro* del contenedor de la API es `db:5432`.

`localhost` dentro de un contenedor es **ese contenedor**, no la máquina. Es el error que todos
cometen una vez. Y para enredarlo más: `ports: "5432:5432"` publica Postgres en el host, así que
desde la laptop —fuera de compose— sí es `localhost:5432`. Las dos cosas son ciertas a la vez, y
por eso confunde.

### `depends_on` no espera a que esté listo

`depends_on: [db]` a secas sólo garantiza el **orden de arranque**. Pero "iniciado" no es
"aceptando conexiones": Postgres tarda unos segundos más. La forma correcta es el par:

- en `db`, un `healthcheck` con `pg_isready`;
- en `api`, `depends_on: db: condition: service_healthy`.

Es el mismo concepto que separa `/healthz` de `/readyz`, aplicado un nivel más abajo: *arrancado*
y *listo* son estados distintos.

### Volúmenes: sin ellos, los datos se van

Un contenedor escribe en su capa escribible, que **muere con él**. `docker compose down` borra la
base de datos entera. Un volumen nombrado desacopla los datos del ciclo de vida del contenedor.

### El `.env` de compose no es el `.env` de la app

Se parecen y no son lo mismo:

- compose lee un `.env` del directorio del `docker-compose.yml` y sustituye `${VAR}` **al leer el
  YAML** — sirve para no repetir el password en dos sitios del archivo;
- el bloque `environment:` define variables **dentro del contenedor**, que es lo que la app lee.

## 2.11 · Esquema y migraciones

### Postgres no indexa las claves foráneas

Crea índice automáticamente para la **clave primaria** y para los `UNIQUE`. Para una **clave
foránea, no**. Y la clave foránea es justo la columna por la que se filtra siempre
(`WHERE project_id = ...`, y todos los JOIN). Es de las omisiones más comunes y sale cara en
cuanto la tabla crece.

Otros motores sí lo hacen (MySQL/InnoDB crea el índice solo), así que la costumbre de otro stack
engaña. En Postgres hay que declararlo.

### `--autogenerate` produce un borrador, no un resultado

Alembic compara el `Base.metadata` contra el esquema real y escribe una migración. Detecta bien
tablas y columnas nuevas, pero:

- se le escapan cambios de `server_default` y algunos de restricción;
- **un renombre lo interpreta como borrar una columna y crear otra** — pérdida de datos
  silenciosa, y en el diff parece inofensivo;
- los cambios de tipo a veces salen sin el `USING` que Postgres necesita.

Por eso el archivo generado **se lee entero antes de aplicarlo**. Y la `downgrade()` se escribe
bien o se borra: una reversión rota es peor que ninguna, porque da confianza falsa el día que
hace falta.

La prueba que cierra el ciclo, y que cuesta treinta segundos:
`upgrade head` → `downgrade -1` → `upgrade head`.

### Dónde corren las migraciones, y expand/contract

**No al arrancar la app.** Con dos tasks en ECS, las dos ejecutarían `upgrade head` a la vez y
competirían. Corren como una **task de una sola vez, antes** de actualizar el servicio (punto 20).

La parte sutil, y la que preguntan: durante un rolling deploy **el código viejo y el nuevo corren
a la vez contra un único esquema**. Así que cada migración tiene que ser compatible hacia atrás
con la versión anterior del código:

| Deploy | Migración | Código |
|---|---|---|
| 1 | añade la columna **nullable** | todavía no la usa |
| 2 | — | empieza a escribirla y leerla |
| 3 | la vuelve `NOT NULL` / borra la vieja | ya nadie usa la vieja |

**Nunca renombrar ni borrar una columna en la misma release que cambia el código.**

### `passive_deletes=True` — quién borra los hijos

Con `cascade="all, delete-orphan"` a secas, al borrar un proyecto SQLAlchemy **carga en memoria
todas sus tareas y emite un `DELETE` por cada una**. Con `passive_deletes=True` confía en el
`ON DELETE CASCADE` de la base y emite uno solo.

Para un proyecto con 10 000 tareas es la diferencia entre 1 sentencia y 10 001. La condición es
que el `ondelete="CASCADE"` exista de verdad en la clave foránea — si no, quedan filas huérfanas.
Las dos piezas van juntas o no van.

### Enum nativo vs `CHECK`

Un `ENUM` de Postgres se ve más limpio, pero añadir un valor es un `ALTER TYPE` incómodo de
migrar y de revertir. Un `String` con una restricción `CHECK` se cambia con una migración normal,
y la validación de cara al usuario la hace Pydantic, que es donde el valor entra. Menos elegante
en el diagrama, mucho más fácil de evolucionar.

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

## [3] El makefile — ergonomía local, nunca CI

**Qué hice:** `makefile` con `fmt`, `lint`, `plan`, `apply`, `destroy` y un `help` autodocumentado
como target por defecto. Encapsula el `export TF_VAR_aws_profile=taskflow-dev` que antes había
que recordar en cada terminal nueva.

**Por qué así:**
- **CI no usa este archivo, a propósito.** `pr.yml` llama a terraform directamente porque en el
  runner `TF_VAR_aws_profile` debe quedar **sin definir** para que el provider caiga a las
  credenciales OIDC (ver [5.6]). Un `make plan` en CI reintroduciría en silencio el bug del
  perfil. El comentario de cabecera del makefile existe para que nadie "mejore" el workflow
  haciéndolo usar make.
- **`?=` en vez de `=`** — asigna sólo si la variable no viene ya del entorno. El día que exista
  prod: `TF_ENV=infra/envs/prod make plan`, sin tocar el archivo.
- **`terraform -chdir=` en vez de `cd`** — cada línea de una receta corre en su **propio shell**;
  un `cd` en una línea no afecta a la siguiente. `-chdir` elimina esa trampa clásica de make.
- **`local` y `test` aplazados** — no hay app ni tests que envolver. Un target vacío es peor que
  no tenerlo; llegan con los puntos 10 y 11.

**Concepto:**
- `.PHONY` declara que el target no produce un archivo con ese nombre. Sin él, si un día existe
  un archivo llamado `plan` en la raíz, `make plan` diría "up to date" y no ejecutaría nada.
- `export` en make pasa la variable a los procesos hijos; Terraform lee cualquier
  `TF_VAR_<nombre>` del entorno — las dos piezas juntas son lo que hace funcionar el atajo.
- El `help` autodocumentado: los `## comentario` de cada target son datos, no decoración — el
  grep/awk los convierte en la salida de `make help`. Patrón estándar en la industria.

**Trampa:** el archivo se llama `makefile` en minúscula. GNU make lo encuentra (su orden de
búsqueda es `GNUmakefile`, `makefile`, `Makefile`), pero la convención visible es `Makefile` y
algún tooling ajeno a make puede buscar sólo esa forma.

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

## [8] `pyproject.toml` real — adelantado del Bloque C

**Qué hice:** el `pyproject.toml` dejó de ser un placeholder: `[project]` con las dependencias de
la app (FastAPI, uvicorn, SQLAlchemy, Alembic, psycopg 3, pydantic-settings), grupo `dev`
(pytest, httpx, pip-audit), configuración de pytest y ruff, y un `uv.lock` commiteado. Vino en el
mismo PR que el makefile, fuera del orden del roadmap — el manifiesto nació antes que el paquete.

**Por qué cada pieza:**
- **uv + `uv.lock` commiteado** — misma lógica que `.terraform.lock.hcl` en los root modules
  (ver 2.3): el manifiesto declara rangos, el lock congela versiones exactas. Sin lock, dos
  instalaciones en días distintos producen entornos distintos.
- **`[dependency-groups]` (PEP 735) y no `[project.optional-dependencies]`** — los extras son
  para el *consumidor* del paquete (`taskflow[dev]` se publicaría); los grupos son para
  *desarrollar* el paquete y no se publican. pytest no es una feature opcional de la app.
- **`psycopg[binary]` v3, no psycopg2** — el driver actual, con rueda binaria para no compilar
  en local. En el Dockerfile (punto 10) se decidirá si conviene otra variante.
- **`pydantic-settings`** — la configuración entrará por variables de entorno (12-factor), que
  es exactamente como ECS inyecta el bloque `secrets` del task definition (punto 16). La app se
  configura igual en local y en Fargate.
- **httpx en dev** — es lo que usa el `TestClient` de FastAPI; los tests del punto 11 lo piden.
- **pip-audit en dev** — el análogo Python de checkov: escanear dependencias por CVEs conocidos.
  Candidato a job de CI en el punto 11.

**Concepto:** hatchling con `packages = ["app"]` — el build sólo empaqueta `app/`; `worker/` se
decidirá cuando exista. `requires-python = ">=3.12"` fija el suelo del intérprete igual que
`required_version` lo hace con Terraform.

**Trampa:** `packages = ["app"]` apunta a un directorio que hoy sólo tiene un README — hasta que
el punto 9 cree `app/__init__.py`, el proyecto no es instalable como paquete. Consecuencia de
adelantar el paso: revisarlo apenas exista la app.

## [9] `/healthz` y `/readyz` — la primera línea de aplicación

**Qué hice:** `app/__init__.py`, `config.py` con pydantic-settings, `db.py` con el engine de
SQLAlchemy, y `main.py` con los dos endpoints. Primer código Python del proyecto, después de todo
el Bloque B — el carril antes que el tren, cumplido.

**Por qué DOS endpoints y no uno.** Es la decisión de la que cuelga todo lo demás:

| | Pregunta que responde | Quién lo consume | Qué provoca si falla |
|---|---|---|---|
| `/healthz` | ¿está vivo el proceso? | `HEALTHCHECK` de Docker, ECS | **reinicia** el contenedor |
| `/readyz` | ¿puedo atender tráfico? | el target group del ALB | lo **saca de rotación**, sin matarlo |

Si `/healthz` checara la base y la base se cae, el orquestador reiniciaría *todos* los
contenedores en bucle — convirtiendo una caída de base de datos en una caída total, y encima
impidiendo que la app se recupere sola cuando la base vuelva. Con la separación correcta, una
caída de base deja la app viva, fuera de rotación, y vuelve sola.

**Conceptos que entraron con esto:**

- **pydantic-settings y 12-factor.** Cada campo de `Settings` mapea a una variable de entorno del
  mismo nombre. Es *exactamente* el mecanismo con el que ECS inyectará el bloque `secrets` del
  punto 21: la app se configura igual en la laptop y en Fargate, y la diferencia está en quién
  pone las variables, no en el código.
- **`pool_pre_ping=True`.** Antes de entregar una conexión del pool, lanza un ping barato; si está
  muerta la descarta y abre otra. Sin esto, la primera petición después de un failover de RDS o de
  un reinicio de Postgres falla con una conexión rancia.
- **No filtrar el error al cliente.** El mensaje de un fallo de conexión trae el host y el usuario
  de la base. Va al log con `logger.exception`; al cliente sólo `{"db": "fail"}`.
- **503 y no 500.** 503 dice *"estoy sano, mi dependencia no"*; 500 dice *"estoy roto"*. Importa
  para la alarma de 5xx del punto 32: son diagnósticos distintos a las tres de la mañana.

**Dos trampas, las dos en la Parte 4:** el `raise` fuera del `except` (Problema 10) y el `env_file`
relativo al directorio de trabajo (Problema 11).

## [10] Docker y compose — `/readyz` en verde por primera vez

**Qué hice:** `Dockerfile` multi-etapa, `.dockerignore`, `docker-compose.yml` con Postgres y la
API, y los targets `local` y `test` del makefile. La teoría completa está en 2.9 y 2.10.

**El hito:** `curl localhost:8000/readyz` → `200 {"status":"ok","checks":{"db":"ok"}}`. Es la
primera vez que el endpoint puede decir la verdad, porque hasta ahora no había base contra la cual
comprobar nada. Verificado también: el contenedor corre como `uid=100(app)` —no root—, el
`HEALTHCHECK` de Docker reporta `healthy`, y la imagen pesa 298 MB.

**Decisiones y su porqué:**

| Decisión | Por qué |
|---|---|
| Builder = imagen oficial de `uv` | trae uv y Python listos; la etapa final no hereda nada de eso |
| `--frozen --no-dev --no-install-project` | `--frozen` obliga a respetar `uv.lock` (falla si está desactualizado, en vez de resolver por su cuenta); `--no-dev` deja fuera pytest y ruff, que no pintan nada en producción |
| `HEALTHCHECK` contra `/healthz`, no `/readyz` | aquí se ve el concepto de [9] en la práctica: este check decide **reiniciar**, y no quiero reinicios porque la base esté caída |
| `UV_COMPILE_BYTECODE=1` | precompila los `.pyc` en build; el arranque del contenedor es más rápido, que es lo que importa cuando ECS levanta una task |
| `PYTHONUNBUFFERED=1` | logs al instante en vez de a trozos → ver 2.9 |
| Postgres con `healthcheck` + `condition: service_healthy` | "arrancado" no es "listo"; el mismo concepto de [9], un nivel más abajo |

**Pendiente de este punto** (no bloquea, pero está anotado):

- `COPY app ./app` en la etapa builder es trabajo muerto: con `--no-install-project`, la etapa
  final copia el código del contexto, no del builder. Sobra.
- La etapa final debe fijarse a `python:3.12-slim-bookworm` para igualar el SO del builder →
  Problema 12.
- Falta un volumen nombrado para Postgres: hoy `docker compose down` borra la base. Lo necesitaré
  en cuanto llegue Alembic (punto 11), para probar migraciones sobre datos que sobrevivan.
- El password está escrito dos veces en el compose; con la sustitución `${VAR}` de 2.10 se
  escribe una sola vez.
- Los targets `local` y `test` del makefile no llevan comentario `##`, así que **no aparecen en
  `make help`** — el `help` se autogenera de esos comentarios (ver [3]).

## [11] `Project` / `Task` y la primera migración

**Qué hice:** `app/models.py` con el `Base` declarativo y los dos modelos en estilo tipado de
SQLAlchemy 2.0, Alembic configurado, y la primera migración aplicada. La teoría está en 2.11.

**Verificado de punta a punta**, no sólo "aplicó":

| Prueba | Resultado |
|---|---|
| `upgrade head` → `downgrade -1` → `upgrade head` | el ciclo cierra; tras el downgrade sólo queda `alembic_version` |
| Esquema real con `\d tasks` | índice `ix_tasks_project_id`, `CHECK`, FK con `ON DELETE CASCADE`, `timestamptz` con `now()` |
| Borrar un proyecto con 2 tareas | `tareas_antes = 2` → `tareas_despues = 0`. El CASCADE funciona en la base |
| Insertar `status = 'inventado'` | rechazado por `ck_tasks_status` |

**Las cinco decisiones de esquema, y por qué cada una:**

| Decisión | Por qué |
|---|---|
| `index=True` en `project_id` | Postgres **no** indexa las FK solas → 2.11. Es la columna de todos los filtros y JOINs |
| `DateTime(timezone=True)` + `server_default=func.now()` | un datetime naive es un bug invisible; y que el default lo ponga la base la hace inmune a la deriva del reloj de un contenedor |
| `status` como `String` + `CHECK` | un ENUM nativo es doloroso de migrar → 2.11 |
| `ondelete="CASCADE"` explícito | qué pasa al borrar un proyecto es una decisión, no un default heredado |
| `id` entero secuencial | está bien, **pero**: es enumerable y filtra cuántos registros hay. Ojo con la trampa conceptual — un ID difícil de adivinar **no** es el control contra BOLA; el control es el `WHERE` por dueño del punto 13. Un UUID es defensa en profundidad, no la defensa |

**La pieza fina:** `passive_deletes=True` junto al `cascade="all, delete-orphan"`. Sin ella,
borrar un proyecto haría que SQLAlchemy cargara todas sus tareas en memoria y emitiera un `DELETE`
por cada una. Con ella, confía en el `ON DELETE CASCADE` de la base y emite uno. Las dos piezas
—la del ORM y la de la FK— van juntas o dejan filas huérfanas → 2.11.

**Decisión sobre la URL:** `env.py` la toma de `app.config.settings` con `set_main_option`, en vez
del `sqlalchemy.url` del `alembic.ini`. Ese archivo va commiteado, así que la alternativa era
meter credenciales al repositorio. De paso, Alembic y la app leen la misma configuración en local,
en compose y en ECS.

**Trampa colateral:** al mover el password del compose a `${VAR}` en el `.env` de la raíz, el
`.env` pasó a tener claves (`POSTGRES_*`) que `Settings` no declara, y pydantic-settings las
rechazaba. Arreglado con `extra="ignore"`. Es la costura entre los dos usos del mismo archivo que
describe 2.10.

**Pendiente menor:** `alembic.ini` conserva la línea de ejemplo
`sqlalchemy.url = driver://user:pass@localhost/dbname`. No hace nada —`env.py` la sobreescribe—
pero es configuración muerta que confunde a quien lea, y el patrón `user:pass` es justo lo que
buscan los escáneres de secretos. Vaciarla.

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
| 10 | `/readyz` devuelve **500** donde el código dice 503 | `raise ... from err` fuera del `except` |
| 11 | La app arranca desde `app/` pero no desde la raíz | `env_file` es relativo al directorio de trabajo |
| 12 | — (todavía ninguno) | `python:3.12-slim` se movió de bookworm a trixie |

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

### Problema 10 — `raise ... from err` fuera del `except` ⭐

**Síntoma:** con Postgres apagado, `/readyz` devolvía **500 Internal Server Error** en vez del 503
que el código dice claramente que devuelve. Ninguna herramienta lo marcó: ruff en verde, la app
arranca, y con la base encendida el endpoint funciona perfecto.

**Causa:** el `raise HTTPException(503) from err` estaba indentado **fuera** del bloque `except`.
Python **borra el nombre de la variable de excepción al salir del `except`** — es un `del err`
implícito que el lenguaje hace a propósito, para no retener el traceback completo en memoria y
crear un ciclo de referencias. Cuando la línea del `raise` se ejecutaba, `err` ya no existía:

```
UnboundLocalError: cannot access local variable 'err'
```

FastAPI ve una excepción no manejada y responde 500. El `HTTPException(503)` nunca llegaba a
construirse.

**Arreglo:** el `raise` va **dentro** del `except`.

**Por qué vale la pena recordarlo:** es un error que sólo aparece en el camino de fallo. El camino
feliz —el que pruebas mientras desarrollas— nunca lo toca. Es exactamente el argumento a favor de
los tests del punto 16: el caso que no pruebas es el que se rompe, y aquí el caso no probado *era
el manejo de errores*.

**Y el impacto real, más allá del código:** en el punto 32 hay una alarma sobre los 5xx del ALB.
Un `/readyz` que responde 500 cuando la base está caída dispara la alarma de "hay un bug en la
app" en vez de la de "la dependencia no está".

### Problema 11 — `env_file` es relativo al directorio de trabajo

**Síntoma:** la app arrancaba desde `app/` pero fallaba desde la raíz del repo con
`ValidationError: database_url — Field required`. Al mover el `.env` a la raíz, se invirtió: ahora
fallaba desde `app/`. Parecía que el archivo "no servía en la raíz".

**Causa:** `SettingsConfigDict(env_file=".env")` resuelve la ruta contra el **directorio desde el
que ejecutas**, no contra el módulo donde está escrita. El comportamiento no dependía de dónde
estaba el archivo sino de desde dónde arrancaba yo.

**Arreglo:** una ruta absoluta calculada desde el propio módulo,
`Path(__file__).resolve().parent.parent / ".env"`, y el `.env` en la raíz. Verificado: funciona
desde la raíz, desde `app/` y desde `/`.

**El concepto que quedó claro, y que es el importante:** en el contenedor **no hay ningún `.env`**.
La configuración llega como variables de entorno de verdad, y pydantic-settings les da
**precedencia sobre el archivo** — y si el `.env` no existe, simplemente lo ignora en vez de
fallar. Por eso el mismo código sirve en los dos sitios sin un `if`:

| Dónde | Qué pasa |
|---|---|
| laptop | no hay `DATABASE_URL` en el entorno → cae al `.env` de la raíz |
| compose / ECS | `DATABASE_URL` viene del entorno → gana, y el `.env` ni siquiera existe |

**Por qué el `.env` va en la raíz y no junto al código:** compose lo busca ahí, y un `.env`
viviendo dentro de `app/` es una invitación a que un `COPY` lo hornee en una capa de la imagen
→ ver 2.9.

### Problema 12 — `python:3.12-slim` cambió de Debian por debajo

**Síntoma:** ninguno todavía — y ése es el punto. Lo encontré comparando las dos etapas del
Dockerfile, no porque algo fallara.

**Causa:** el builder usa `uv:python3.12-bookworm-slim` (Debian **bookworm**, Python 3.12.12) y la
etapa final usa `python:3.12-slim`, que **ya apunta a Debian trixie** (Python 3.12.13). El venv se
construye contra un sistema y se ejecuta en otro.

Hoy funciona por suerte: glibc es compatible hacia adelante, así que una rueda compilada en
bookworm corre en trixie. **Al revés reventaría**, y el día que el tag se vuelva a mover la
lotería puede salir al otro lado.

**Arreglo:** fijar la etapa final a `python:3.12-slim-bookworm`, para que las dos etapas sean el
mismo sistema operativo.

**La lección general:** un tag de imagen **no es una versión**, es un puntero que alguien más
mueve. Es la misma disciplina que `required_version` y `~> 6.0` en Terraform, o que commitear el
`uv.lock`: si no lo fijas tú, lo decide otro y te enteras el día que se rompe.

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
