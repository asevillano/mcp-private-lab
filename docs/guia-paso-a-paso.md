# Guía paso a paso: agente de Copilot Studio con un MCP privado en GCP

Guía manual y explicada para montar la solución de principio a fin, por portal o por CLI. Cada paso
explica **para qué** sirve lo que se hace, **dónde** se hace, cómo se **comprueba**, qué hacer si
**falla** y qué hay que acordar con cada equipo de la organización.

Complementa al [README](../readme.md), que es la referencia de la arquitectura y el montaje con
scripts. Se ha validado de extremo a extremo en un tenant de pruebas: los identificadores y valores
reales se han sustituido por marcadores (`<TENANT_ID>`, `<API_APP_ID>`…). Los rangos IP, regiones y
nombres son **ejemplos**: sustitúyelos por los tuyos.

> **Escenario.** El servidor MCP está en **Google Cloud**, sin acceso desde Internet, y se llega a él
> por una **VPN entre Azure y GCP**. En el ejemplo es un servicio de Cloud Run interno; el Paso 8
> explica qué cambia si los MCP están detrás de un F5 o de un balanceador interno. Si el MCP está
> on-premises, la conectividad es la misma idea con VPN site-to-site o ExpressRoute.

## Qué se monta

- 🆕 **Se crea:** grupo de usuarios, aplicaciones de Entra ID, entorno de Power Platform, VNets
  delegadas, Enterprise Policy, DNS privado, servidor MCP de prueba y agente.
- 🔍 **Se crea o se revisa:** la conectividad entre Azure y GCP (hub de Azure, VPN Gateway, HA VPN,
  Cloud Router, túneles y endpoint PSC). Muchas organizaciones ya la tienen; cada uno de esos pasos
  explica cómo revisarla y **cómo crearla desde cero**.

## Recorrido

| # | Paso | Tipo |
|---|---|---|
| 1 | [Preparación, accesos y plan de red](#paso-1-de-18-preparación-accesos-y-plan-de-red) | 📋 Preparar |
| 2 | [Grupo de usuarios del piloto (Microsoft 365)](#paso-2-de-18-grupo-de-usuarios-del-piloto-microsoft-365) | 🆕 Crear |
| 3 | [Aplicación de la API del MCP (Entra ID)](#paso-3-de-18-aplicación-de-la-api-del-mcp-entra-id) | 🆕 Crear |
| 4 | [Aplicación cliente OAuth del conector (Entra ID)](#paso-4-de-18-aplicación-cliente-oauth-del-conector-entra-id) | 🆕 Crear |
| 5 | [Entorno de Power Platform y Managed Environment](#paso-5-de-18-entorno-de-power-platform-y-managed-environment) | 🆕 Crear |
| 6 | [VNet hub de Azure y `GatewaySubnet`](#paso-6-de-18-vnet-hub-de-azure-y-gatewaysubnet-crear-o-revisar) | 🔍 Crear o revisar |
| 7 | [VPN Gateway de Azure con BGP](#paso-7-de-18-vpn-gateway-de-azure-con-bgp-crear-o-revisar) | 🔍 Crear o revisar |
| 8 | [Red de GCP: VPC, subred y endpoint PSC](#paso-8-de-18-red-de-gcp-vpc-subred-y-endpoint-psc-crear-o-revisar) | 🔍 Crear o revisar |
| 9 | [HA VPN y Cloud Router de GCP](#paso-9-de-18-ha-vpn-y-cloud-router-de-gcp-crear-o-revisar) | 🔍 Crear o revisar |
| 10 | [Túneles IPsec y sesiones BGP, Azure ↔ GCP](#paso-10-de-18-túneles-ipsec-y-sesiones-bgp-azure--gcp-crear-o-revisar) | 🔍 Crear o revisar |
| 11 | [MCP de prueba en Cloud Run](#paso-11-de-18-mcp-de-prueba-en-cloud-run) | 🆕 Crear |
| 12 | [VNets delegadas de Power Platform](#paso-12-de-18-vnets-delegadas-de-power-platform) | 🆕 Crear |
| 13 | [Peering con el hub (*gateway transit*) y rutas](#paso-13-de-18-peering-con-el-hub-gateway-transit-y-rutas) | 🆕 Crear |
| 14 | [DNS privado para el nombre del MCP](#paso-14-de-18-dns-privado-para-el-nombre-del-mcp) | 🆕 Crear |
| 15 | [Enterprise Policy (VNet Support)](#paso-15-de-18-enterprise-policy-vnet-support) | 🆕 Crear |
| 16 | [Vincular la política al entorno y diagnóstico desde Power Platform](#paso-16-de-18-vincular-la-política-al-entorno-y-diagnóstico-desde-power-platform) | 🆕 Crear |
| 17 | [Agente y herramienta MCP en Copilot Studio](#paso-17-de-18-agente-y-herramienta-mcp-en-copilot-studio) | 🆕 Crear |
| 18 | [Publicar en Teams y dar acceso a otro usuario](#paso-18-de-18-publicar-en-teams-y-dar-acceso-a-otro-usuario) | 🆕 Crear |

Para **retirar** todo lo creado, sigue el orden de la sección 8 del README (*Recursos del
laboratorio, costes y retirada*): primero desvincula la Enterprise Policy del entorno, porque una
subred delegada en uso no se puede borrar.

---

## Paso 1 de 18. Preparación, accesos y plan de red

**Objetivo:** antes de crear nada, asegurarse de que:

1. las herramientas instaladas tienen las funciones que usa la guía;
2. cada herramienta trabaja en el tenant, la suscripción y el proyecto correctos;
3. se tienen (o se han pedido) los permisos de cada parte;
4. los rangos de IP de todas las redes no se solapan;
5. hay una ficha donde ir guardando los identificadores que se generen.

**Por qué es importante:** si falla cualquiera de estos puntos, los pasos siguientes fallan por
motivos que no tienen nada que ver con la solución, y es muy difícil distinguirlo sobre la marcha.

### 1.1 Herramientas y versiones válidas

**Para qué:** la solución se configura en cuatro sitios distintos y cada herramienta se ocupa de uno.
Con una versión demasiado antigua, un comando de la guía puede no existir o devolver campos con otro
nombre: parecería que la configuración está mal cuando el problema es la herramienta.

| Herramienta | Qué configura en esta solución | Versión mínima | Por qué ese mínimo | Probado con |
|---|---|---|---|---|
| **PowerShell** | Ejecuta los scripts del repositorio (`tools\`, `infra\gcp\`) | **7.0** | El script de la VPN de GCP genera la clave IPsec con un método de .NET (`RandomNumberGenerator.Fill`) que no existe en Windows PowerShell 5.1. Comprobado: en 5.1 falla | 7.6.10 |
| **Azure CLI** (`az`) | Entra ID (aplicaciones, grupos, roles), redes de Azure, VPN Gateway, DNS privado y Enterprise Policy | **2.37.0** | Desde esa versión, los comandos `az ad …` usan Microsoft Graph ([documentación oficial](https://learn.microsoft.com/en-us/cli/azure/microsoft-graph-migration)). En versiones anteriores, los campos cambian (`objectId` en lugar de `id`) y los comandos de la guía fallan | 2.93.0 |
| **Google Cloud CLI** (`gcloud`) | Red de GCP (VPC, HA VPN, Cloud Router, endpoint PSC) y Cloud Run | No hay mínimo publicado | Se comprueba que existan las opciones concretas que usa la guía (apartado b) | 575.0.0 |
| **Power Platform CLI** (`pac`) | Crear el entorno y activarlo como Managed Environment | No hay mínimo publicado | Igual que `gcloud` | 2.15.1 |

**a) Ver qué versión hay instalada.**
**Para qué:** descartar de entrada las dos incompatibilidades conocidas (PowerShell 5.1 y Azure CLI
anterior a 2.37.0).

```powershell
$PSVersionTable.PSVersion
(az version -o json | ConvertFrom-Json).'azure-cli'
gcloud version | Select-Object -First 1
pac help | Select-Object -First 2
```

- Si PowerShell empieza por **5.**, la consola es Windows PowerShell: abre **PowerShell 7**
  (`pwsh`), o instálalo.
- Si Azure CLI es **anterior a 2.37.0**, actualízalo con `az upgrade`.
- No uses `az version --query '"azure-cli"'`: PowerShell quita las comillas internas al pasar el
  argumento a `az` y el comando falla con `invalid jmespath_type value`.

**b) Comprobar que existen las opciones que usa la guía.**
**Para qué:** para `gcloud` y `pac` no hay una versión mínima documentada para cada opción, así que el
criterio fiable es buscar la opción en la ayuda de la versión instalada. Para `az` sirve como segunda
comprobación. Tarda **de 2 a 4 minutos** porque abre la ayuda de cada comando.

```powershell
function Test-Opcion([string] $Comando, [string] $Opcion) {
    $ayuda = (Invoke-Expression "$Comando --help 2>&1") | Out-String
    '{0,-42} {1,-26} {2}' -f $Comando, $Opcion, $(if ($ayuda -match [regex]::Escape($Opcion)) { 'OK' } else { 'FALTA' })
}
Test-Opcion 'az ad app credential reset'              'display-name'
Test-Opcion 'az network vnet subnet update'           'delegations'
Test-Opcion 'az network vnet peering create'          'use-remote-gateways'
Test-Opcion 'az network private-dns link vnet create' 'registration-enabled'
Test-Opcion 'gcloud run deploy'                       'no-invoker-iam-check'
Test-Opcion 'gcloud compute vpn-gateways create'      'stack-type'
Test-Opcion 'gcloud compute forwarding-rules create'  'target-google-apis-bundle'
Test-Opcion 'pac admin create'                        'macro-region'
Test-Opcion 'pac admin set-governance-config'         'protection-level'
Test-Opcion 'pac environment-management'              'get-supported-locations'
```

| Opción | Paso en el que se usa | Para qué |
|---|---|---|
| `display-name` | 4 y 17 | Poner nombre a los secretos del cliente OAuth, para saber después cuál borrar |
| `delegations` | 12 | Reservar una subred para Power Platform (delegación) |
| `use-remote-gateways` | 13 | Que las VNets de Power Platform usen la VPN del hub (*gateway transit*) |
| `registration-enabled` | 14 | Vincular la zona DNS privada a las VNets sin registrar máquinas automáticamente |
| `no-invoker-iam-check` | 11 | Que Cloud Run no exija autenticación de Google, porque la identidad la valida el MCP con el token de Entra |
| `stack-type` | 9 | Crear la HA VPN de GCP |
| `target-google-apis-bundle` | 8 | Crear el endpoint PSC para llegar a Cloud Run por IP privada |
| `macro-region` | 5 | Crear el entorno en una macrorregión, que es como este tenant asigna la ubicación |
| `protection-level` | 5 | Activar Managed Environment |
| `get-supported-locations` | 5 | Ver qué ubicaciones de entorno admite el tenant |

**Resultado esperado:** **OK** en las 10 líneas.

**Si sale FALTA:** actualiza la herramienta de esa línea (`az upgrade`, `gcloud components update`
o `pac install latest`) y repite la comprobación. Si sigue faltando, esa acción se hace desde el
portal; cada paso indica dónde.

### 1.2 Sesiones en el tenant y el proyecto correctos

**Para qué:** las tres herramientas guardan sus sesiones por separado, y cada una puede seguir
apuntando a otro tenant, suscripción o proyecto de un trabajo anterior. Es la forma más fácil de
crear, sin darse cuenta, las aplicaciones en el tenant corporativo o las redes en otra suscripción.

**Azure.** **Para qué:** las aplicaciones de Entra se crean en el tenant de la sesión, y las redes y
la Enterprise Policy en la suscripción activa.

```powershell
az account show --query "{tenant:tenantId, suscripcion:name, usuario:user.name}" -o table
```

Debe mostrar el tenant `<TENANT_ID>`, la suscripción
`<nombre-de-la-suscripción>` y el usuario `<admin@tu-dominio>`. Solo si no
coinciden:

```powershell
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>
```

**Google Cloud.** **Para qué:** todos los comandos `gcloud` actúan sobre el proyecto configurado. Ahí
están la VPN y el MCP de Cloud Run.

```powershell
gcloud auth list
gcloud config get-value project
```

Debe mostrar la cuenta activa (con `*`) `<tu-cuenta-gcp>` y el proyecto
`<GCP_PROJECT_ID>`. Solo si el proyecto no coincide:

```powershell
gcloud config set project <GCP_PROJECT_ID>
```

**Power Platform.** **Para qué:** `pac` crea el entorno con el usuario del perfil activo, y ese
usuario debe ser administrador de Power Platform en el tenant correcto.

```powershell
pac auth list
```

El perfil activo (con `*`) debe ser de `<admin@tu-dominio>`. No importa a qué
entorno apunte el perfil: crear entornos es una operación de todo el tenant.

- Si el perfil activo es de otro usuario: `pac auth select --index <número>`.
- Si no hay ningún perfil de ese usuario: `pac auth create --name <nombre-perfil>`. Se abre el navegador
  para iniciar sesión. No uses `--tenant`: esa opción solo sirve para iniciar sesión con una
  aplicación (ID de aplicación y secreto o certificado), no con un usuario.

### 1.3 Permisos necesarios

**Para qué:** en una organización, cada parte la hará una persona o un equipo distinto. Pedir los permisos
**antes** de la sesión evita quedarse bloqueados a mitad del montaje.

| Dónde | Permiso | Para qué | Pasos |
|---|---|---|---|
| Entra ID | Application Administrator o Cloud Application Administrator | Registrar las dos aplicaciones y conceder el consentimiento de administrador | 3, 4 |
| Entra ID | Groups Administrator, o ser propietario del grupo | Crear el grupo del piloto y gestionar sus miembros | 2 |
| Entra ID | Licencia Entra ID P1 | Asignar el rol de la aplicación **a un grupo** en lugar de usuario a usuario | 3 |
| Azure | Network Contributor (o Contributor) en la suscripción | VNets, peering, VPN Gateway y DNS privado | 6, 7, 10, 12 a 15 |
| Azure | Proveedores `Microsoft.Network` y `Microsoft.PowerPlatform` registrados | Sin `Microsoft.PowerPlatform`, la suscripción no admite el tipo de recurso de la Enterprise Policy | 15 |
| Power Platform | Power Platform Administrator | Crear el entorno, activar Managed Environment y vincular la política | 5, 16 |
| Power Platform | Capacidad de Dataverse y licencias de Copilot Studio | Para el entorno y el agente | 5, 17 |
| Google Cloud | `compute.networkAdmin`, `run.admin`, `dns.admin` y `servicedirectory.editor` en el proyecto | VPC, VPN, Cloud Router, Cloud Run y endpoint PSC | 8 a 11 |

Comprueba los proveedores de Azure.
**Para qué:** un proveedor de recursos sin registrar hace fallar la creación con un error que no
menciona el registro.

```powershell
az provider show -n Microsoft.PowerPlatform --query registrationState -o tsv
az provider show -n Microsoft.Network --query registrationState -o tsv
```

**Resultado esperado:** `Registered` en los dos.

**Si no está registrado:** `az provider register -n Microsoft.PowerPlatform`. Tarda unos minutos
y necesita permisos de colaborador sobre la suscripción.

### 1.4 Plan de direcciones IP

**Para qué:** Azure y GCP se intercambiarán las rutas de sus redes por BGP.
- **Si dos redes comparten rango, el router no sabe adónde enviar el tráfico** y la conexión falla
  o llega a la red equivocada.
- Una subred delegada a Power Platform **no se puede redimensionar** sin abrir un caso a Microsoft.

Por eso los rangos se deciden antes de crear nada.

| Red | Rango | Ubicación | Estado |
|---|---|---|---|
| Hub de Azure (con `GatewaySubnet`) | `10.91.0.0/16` (`GatewaySubnet` `10.91.255.0/27`) | North Europe | Existente o nuevo (Paso 6) |
| VPC de GCP | `10.95.0.0/24` | europe-west1 | Existente o nueva (Paso 8) |
| Endpoint PSC de GCP | `10.96.0.10/32` | VPC de GCP | Existente o nuevo (Paso 8) |
| Direcciones BGP de los túneles (APIPA) | `169.254.21.0/30` y `169.254.22.0/30` | Túneles VPN | Existentes o nuevas (Paso 10) |
| **VNets delegadas de Power Platform** | **`10.97.0.0/24`** y **`10.98.0.0/24`** (subredes `/26`) | Las dos regiones del entorno (Paso 5) | **Nuevas** (Paso 12) |

**Por qué `/26`:** un entorno que no es de producción usa entre 6 y 10 IP, y uno de producción entre
25 y 30. Una `/26` tiene 64 direcciones, de las que Azure se reserva 5. Las dos subredes deben ser
**del mismo tamaño**.

**En la organización:** pide al equipo de red los rangos que ya usan en Azure, GCP y on-premises (no solo
los del MCP), y reserva dos libres para Power Platform.

### 1.5 Ficha de valores

**Para qué:** durante el montaje se generan unos 10 identificadores (aplicaciones, grupo, entorno…)
que se necesitan en pasos posteriores.

Además, los scripts de `tools\` leen de la ficha los valores que no se les pasan como parámetro. Por
defecto buscan `config\lab.config.json`; con la variable `MCP_LAB_CONFIG` leen esta ficha. Así se
pueden tener varios montajes (por ejemplo, desarrollo y pruebas) sin mezclar sus valores.

La ficha está **fuera del repositorio** para que nunca acabe publicada en GitHub.

**Crear la ficha** (una sola vez):

```powershell
@'
{
  "tenantId": "<TENANT_ID>",
  "entra": { "connectorClientId": "", "pilotGroupObjectId": "", "pilotGroupName": "MCP-Piloto" },
  "powerPlatform": { "environmentId": "", "orgUrl": "", "regions": ["", ""], "connectorDisplayName": "MCP Piloto" },
  "gcp": { "projectId": "<GCP_PROJECT_ID>", "cloudRunService": "mcp-piloto" }
}
'@ | Set-Content -LiteralPath "$env:USERPROFILE\mcp-piloto.config.json" -Encoding utf8
```

La línea final `'@` debe quedar **al principio de la línea**, sin espacios delante.

**En cada sesión nueva de PowerShell:**
**Para qué:** situarse en el repositorio, donde están los scripts, y hacer que lean esta ficha. La
variable solo dura lo que dura la sesión.

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
```

**Comprobación.**
**Para qué:** confirmar que los scripts leerán esta ficha y no otra.

```powershell
. .\tools\lab-config.ps1
$script:LabConfigPath
Get-LabSetting 'gcp.projectId'
```

**Resultado esperado:**
- La primera línea muestra `C:\Users\<tu-usuario>\mcp-piloto.config.json`. Si muestra
  `…\config\lab.config.json`, falta la línea `$env:MCP_LAB_CONFIG` y los scripts usarían otro
  fichero.
- La segunda muestra `<GCP_PROJECT_ID>`.

Los campos vacíos se rellenan en los pasos siguientes. Si un script necesita uno que siga vacío, se
detiene e indica cuál falta.

### Lista de control del Paso 1

- [ ] PowerShell 7 o superior y Azure CLI 2.37.0 o superior.
- [ ] Las 10 comprobaciones de opciones en **OK**.
- [ ] Azure, Google Cloud y Power Platform en el tenant, la suscripción y el proyecto correctos.
- [ ] Los dos proveedores en `Registered`.
- [ ] La ficha creada, y `$script:LabConfigPath` apunta a ella.

---

## Paso 2 de 18. Grupo de usuarios del piloto (Microsoft 365)

**Objetivo:** crear la **única lista de quién puede usar la solución**. En lugar de dar permisos usuario
a usuario en cuatro sitios, se dan al grupo. Para dar o quitar acceso basta con añadir o quitar a la
persona del grupo.

> **Por qué un grupo de Microsoft 365:** permite **compartir el agente con el grupo** en lugar de usuario
> a usuario. Un grupo de seguridad sin correo también sirve para todo lo demás, pero el diálogo
> *Compartir* de Copilot Studio no lo encuentra. Este tipo de grupo se ha validado de extremo a extremo.

### Para qué se usa el grupo

| Dónde se usa | Paso | Qué controla | Si el usuario no está | ¿Funciona con Microsoft 365? |
|---|---|---|---|---|
| Grupo de seguridad del entorno de Power Platform | 5 | Quién puede **entrar** al entorno | No puede usar el agente | ✅ Documentado: el entorno admite grupos de seguridad y de Microsoft 365 ([Control user access](https://learn.microsoft.com/en-us/power-platform/admin/control-user-access)) |
| Rol `MCP.User` de la API del MCP | 3 | A quién **emite Entra el token** para el MCP | Entra no le da token | ✅ **Validado en el Paso 3** (el token incluye `roles = MCP.User`) |
| Equipo de Dataverse con lectura del conector | 18 | Quién puede **crear su conexión** | *Connector information unavailable* | ✅ **Validado en el Paso 18**: equipo de tipo *Office group*, `teamtype 3` ([Manage group teams](https://learn.microsoft.com/en-us/power-platform/admin/manage-group-teams)) |
| **Compartir el agente** en Copilot Studio | 18 | Quién puede **instalar y chatear** con el agente | *Su organización impidió la instalación* | ✅ **Validado en el Paso 18** (requiere `SecurityEnabled = true`, [Share agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/admin-share-bots)) |

### Tres propiedades que deciden si el grupo sirve

| Propiedad | Valor necesario | Por qué |
|---|---|---|
| `securityEnabled` | **`true`** | Sin ella, el grupo no puede recibir permisos: no se puede compartir el agente con él ni usarlo para controlar el acceso. Los grupos de Microsoft 365 creados **fuera de Entra** (desde Outlook o Teams) la tienen en `false`. Compruébalo si reutilizas un grupo existente |
| `visibility` | **`Private`** | Si fuera **pública**, cualquier usuario de la organización podría unirse **por su cuenta** y obtendría acceso al MCP |
| Miembros | **Directos** | La asignación de roles de aplicación de Entra **no tiene en cuenta los grupos anidados** |

### 2.1 Comprobar los usuarios y que el nombre está libre

**Para qué:** para añadir a un usuario al grupo hace falta su **identificador de objeto** (`objectId`).
Además, el alias de correo de un grupo de Microsoft 365 **debe ser único** en el tenant.

```powershell
az ad user show --id <admin@tu-dominio> --query "{upn:userPrincipalName, objectId:id}" -o table
az ad user show --id <usuario2@tu-dominio> --query "{upn:userPrincipalName, objectId:id}" -o table
az ad group list --query "[?mailNickname=='mcp-piloto' || displayName=='MCP-Piloto'].displayName" -o tsv
```

**Resultado esperado:**
- Tu usuario administrador → su `objectId`.
- El segundo usuario del piloto → su `objectId`.
- La tercera consulta **vacía**: el nombre y el alias están libres.

**Por qué el alias `objectId`:** la salida en tabla de `az` **oculta las columnas que se llaman `id`**.

**Consejo:** deja fuera del grupo a un tercer usuario, para comprobar más adelante que un usuario sin
grupo es rechazado.

### 2.2 Crear el grupo

**Opción A (recomendada): CLI con Microsoft Graph.**
**Para qué:** fija en una sola llamada las tres propiedades clave, el propietario y los miembros, sin
depender de valores por defecto.

```powershell
$body = "$env:TEMP\grupo-mcp-piloto.json"
@'
{
  "displayName": "MCP-Piloto",
  "description": "Usuarios piloto del agente MCP piloto",
  "mailNickname": "mcp-piloto",
  "mailEnabled": true,
  "securityEnabled": true,
  "groupTypes": ["Unified"],
  "visibility": "Private",
  "owners@odata.bind": ["https://graph.microsoft.com/v1.0/users/<ADMIN_OBJECT_ID>"],
  "members@odata.bind": [
    "https://graph.microsoft.com/v1.0/users/<ADMIN_OBJECT_ID>",
    "https://graph.microsoft.com/v1.0/users/<USER2_OBJECT_ID>"
  ]
}
'@ | Set-Content -LiteralPath $body -Encoding utf8
$GRUPO = az rest --method POST --headers Content-Type=application/json `
  --url https://graph.microsoft.com/v1.0/groups --body "@$body" --query id -o tsv
Remove-Item $body
$GRUPO
```

| Campo | Para qué |
|---|---|
| `groupTypes: ["Unified"]` | Es lo que convierte el grupo en **de Microsoft 365**. Sin este campo sería un grupo de seguridad |
| `mailEnabled: true` y `mailNickname` | Un grupo de Microsoft 365 siempre tiene correo (`mcp-piloto@<tu-dominio>`) |
| `securityEnabled: true` | Permite usar el grupo para controlar el acceso y para compartir el agente |
| `visibility: Private` | Nadie puede unirse si no lo añade un propietario |
| `owners@odata.bind` | Un grupo de Microsoft 365 **debe tener propietario**. Si lo crea un administrador, Graph no lo asigna solo |
| `members@odata.bind` | Los usuarios del piloto como miembros **directos**. Ser propietario no da permisos si no se es también miembro |

- El cuerpo va en un fichero porque, en Windows, el JSON escrito directamente en la línea de comandos
  falla por el entrecomillado.
- La línea `'@` debe empezar en la primera columna, sin espacios delante.

**Opción B: portal.** [Entra admin center](https://entra.microsoft.com) → **Grupos → Todos los grupos →
Nuevo grupo**:

| Campo | Valor |
|---|---|
| Tipo de grupo | Microsoft 365 |
| Nombre | `MCP-Piloto` |
| Correo electrónico del grupo | `mcp-piloto` |
| Descripción | `Usuarios piloto del agente MCP piloto` |
| Se pueden asignar roles de Microsoft Entra al grupo | **No**. Esa opción es para roles de administración del tenant, no para roles de una aplicación |
| Tipo de pertenencia | Asignado |
| Propietarios | Tu usuario administrador |
| Miembros | Los usuarios del piloto |

Los grupos creados desde el Entra admin center tienen `securityEnabled = true`, según la
documentación de Graph. **La visibilidad no se elige en ese formulario**, así que hay que comprobarla
en 2.3. Después, recupera su ID:

```powershell
$GRUPO = az ad group list --display-name 'MCP-Piloto' --query "[0].id" -o tsv
```

**Espera unos 30 segundos** antes de comprobarlo: el grupo tarda en estar disponible en todo el
directorio.

### 2.3 Comprobar el resultado

**Para qué:** confirmar las tres propiedades clave y los miembros. Si una está mal, no falla aquí,
sino en el Paso 3 o en el 18, y allí cuesta mucho más encontrar la causa.

```powershell
az ad group show --group $GRUPO --query "{nombre:displayName, tipos:join(',', groupTypes), seguridad:securityEnabled, correo:mailEnabled, visibilidad:visibility}" -o table
az ad group owner list --group $GRUPO --query "[].userPrincipalName" -o tsv
az ad group member list --group $GRUPO --query "[].userPrincipalName" -o tsv
```

**Resultado esperado:**
- `tipos` = `Unified`, `seguridad` = `True`, `correo` = `True`, `visibilidad` = `Private`.
- Propietario: tu usuario administrador.
- Miembros: exactamente los usuarios del piloto.

**Si `seguridad` = `False` o `visibilidad` = `Public`**, corrígelo:

```powershell
$fix = "$env:TEMP\grupo-fix.json"
'{ "securityEnabled": true, "visibility": "Private" }' | Set-Content -LiteralPath $fix -Encoding ascii
az rest --method PATCH --headers Content-Type=application/json `
  --url "https://graph.microsoft.com/v1.0/groups/$GRUPO" --body "@$fix"
Remove-Item $fix
```

### 2.4 Guardar el ID del grupo en la ficha

**Qué es «guardar en la ficha»:** escribir el ID del grupo en el campo `entra.pilotGroupObjectId` del
fichero `C:\Users\<tu-usuario>\mcp-piloto.config.json`, creado en el Paso 1.5.

**Para qué:**
1. **No perder el dato.** La variable `$GRUPO` desaparece al cerrar PowerShell; la ficha no.
2. **Que los scripts lo encuentren.** Los scripts del repositorio leen de la ficha lo que no se les
   pasa como parámetro. Por ejemplo, en el Paso 18 el script de acceso al conector tomará de ahí el
   ID del grupo. Si el campo está vacío, el script se detiene y lo indica.

En una consola nueva, ejecuta primero las dos líneas del Paso 1.5. Si no, `$env:MCP_LAB_CONFIG`
estará vacía y el comando fallará.

```powershell
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json        # 1. leer la ficha
$c.entra.pilotGroupObjectId = $GRUPO                                              # 2. poner el ID del grupo
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8   # 3. guardar la ficha
(Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra      # 4. comprobar el resultado
```

**Alternativa a mano:** abre la ficha con `notepad "$env:USERPROFILE\mcp-piloto.config.json"`, pega
el ID entre las comillas de `"pilotGroupObjectId": ""` y guarda, sin borrar comillas ni comas. La
línea 4 confirma que el fichero sigue siendo un JSON válido.

### Quién lo hace y qué acordar

- **Quién lo hace:** el equipo de identidad (Groups Administrator).
- **Qué hay que pedir:** un grupo de Microsoft 365 **privado**, con `securityEnabled = true`, pertenencia
  asignada, sin roles de Entra y con los usuarios del piloto **como miembros directos**.
- **Antes de reutilizar un grupo que ya exista** (por ejemplo, el de un equipo de Teams), revisa
  `securityEnabled` y `visibility` con la consulta de 2.3.
- **Diferencias con un grupo de seguridad que conviene explicar:**
  - Los **propietarios** pueden añadir miembros sin pasar por el equipo de identidad.
  - Puede incluir **invitados**, si el tenant lo permite.
  - Crea **buzón y sitio de SharePoint**.
  - Al eliminarlo, se queda **30 días en la papelera** con el alias reservado.


---

## Paso 3 de 18. Aplicación de la API del MCP (Entra ID)

**Objetivo:** registrar en Entra ID la **API del MCP**. No es código: es la definición que Entra usa
para emitir los tokens que el MCP aceptará.

### Qué define y cómo lo usa el MCP

| Lo que se configura | Campo del token | Qué hace el MCP si no está bien |
|---|---|---|
| URI del identificador de aplicación (`api://<appId>`) | `aud` (audiencia) | 401: el token no es para él |
| Ámbito (permiso delegado) `MCP.Access` | `scp` | 403 |
| Rol de aplicación `MCP.User` | `roles` | 403 |
| Versión del token = 2 | `iss` y `ver` | 401: el emisor no es el esperado |

**Ámbito frente a rol:**
- El **ámbito** dice **qué puede hacer la aplicación** (el conector) en nombre del usuario.
- El **rol** dice **qué usuario** está autorizado.

El MCP exige los dos: tener el conector bien configurado no basta para un usuario sin permiso.

**Tres identificadores que no hay que confundir:**

| Identificador | Qué identifica | Dónde se usa |
|---|---|---|
| `appId` (*Id. de aplicación (cliente)*) | La API en los tokens (`aud`) y en `api://<appId>` | Paso 4, Paso 11 y Paso 17 |
| `objectId` (*Id. de objeto*) del **registro** | El registro, para modificarlo con Graph (`applications/<objectId>`) | 3.2 (CLI) y 3.7 |
| `spId` (*Id. de objeto* de la **aplicación empresarial**) | La instancia de la API en el tenant (`servicePrincipals/<spId>`) | 3.4, 3.5 y Paso 4 |

Si en Graph se usa uno en lugar de otro, la respuesta es *Resource not found*.

**Dos objetos en Entra:**
- El **registro de aplicación** (*Entra ID → Registros de aplicaciones*) es la **definición**: URI,
  ámbitos, roles y versión del token.
- La **aplicación empresarial** o *service principal* (*Entra ID → Aplicaciones empresariales*) es la
  **instancia en el tenant**. En ella se guardan la asignación obligatoria, a quién se ha asignado el
  rol y los consentimientos.

### 3.1 Registrar la aplicación

**Para qué:** crear la definición de la API. Su `appId` será la audiencia de los tokens.

**Portal:** **Entra ID → Registros de aplicaciones → + Nuevo registro**

| Campo | Valor | Para qué |
|---|---|---|
| Nombre | `mcp-piloto-api` | — |
| Tipos de cuenta compatibles | **Solo inquilino único: <tu-tenant>** | Solo usuarios de este tenant obtienen tokens. *Varios inquilinos* abriría la API a otras organizaciones, y las opciones con *cuentas personales* no sirven para usuarios de empresa |
| URI de redirección | Vacía | La API **recibe** tokens; no inicia sesiones. La URI de redirección la tendrá el cliente del conector |
| Service management reference | Vacío | Referencia opcional a una CMDB. Puede ser obligatoria por las normas de la organización |

Después de **Registrar**, carga los identificadores en PowerShell:

```powershell
$r = az ad app list --display-name 'mcp-piloto-api' --query "[0].{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$API_APP = $r.appId; $API_OBJ = $r.objectId
"appId: $API_APP   objectId: $API_OBJ"
```

**CLI (alternativa):**

```powershell
$r = az ad app create --display-name 'mcp-piloto-api' --sign-in-audience AzureADMyOrg --query "{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$API_APP = $r.appId; $API_OBJ = $r.objectId
```

Usa **solo una** de las dos opciones: si haces las dos, tendrás dos aplicaciones con el mismo nombre.

### 3.2 Audiencia, ámbito, rol y versión del token

**Portal**, en **Entra ID → Registros de aplicaciones →** `mcp-piloto-api`:

**A) Exponer una API → URI del identificador de aplicación → Agregar** → acepta `api://<appId>` → **Guardar**.
**Para qué:** es el nombre con el que el conector pedirá el permiso (`api://<appId>/MCP.Access`).
`api://<appId>` siempre es válido; un nombre propio exigiría un dominio verificado.

**B) Exponer una API → + Agregar un ámbito:**

| Campo | Valor | Para qué |
|---|---|---|
| Nombre del ámbito | `MCP.Access` | Lo que aparece en `scp` |
| ¿Quién puede dar el consentimiento? | Administradores y usuarios | Equivale a `type = User`. En el Paso 4 lo concede el administrador para toda la organización |
| Nombres y descripciones de consentimiento | `Acceder al MCP piloto como el usuario` y similares | Textos de la pantalla de consentimiento |
| Estado | Habilitado | Un ámbito deshabilitado no se puede pedir |

**C) Roles de aplicación → + Crear rol de aplicación:**

| Campo | Valor | Para qué |
|---|---|---|
| Nombre para mostrar | `MCP User` | El que se ve al asignarlo |
| Tipos de miembro permitidos | **Usuarios o grupos** | Se asigna a personas y grupos, no a aplicaciones |
| Valor | `MCP.User` | Lo que aparece en `roles`. **Exacto**: el MCP busca ese texto |
| Habilitado | Marcado | — |

**D) Manifiesto** (pestaña *Manifiesto de aplicación de Microsoft Graph*) → dentro de `"api"`, cambia
`"requestedAccessTokenVersion": null` por `2`, sin comillas → **Guardar**. En el manifiesto antiguo,
el campo se llama `accessTokenAcceptedVersion`.
**Para qué:** es **el error más habitual**. `null` significa tokens **v1**, con emisor
`https://sts.windows.net/<tenant>/`. El MCP solo acepta tokens **v2**, con emisor
`https://login.microsoftonline.com/<tenant>/v2.0`, y respondería 401 aunque todo lo demás estuviera
bien. Una aplicación nueva tiene este campo en `null` (comprobado en el tenant).

**E) Cargar los GUID del ámbito y del rol.** Entra los identifica por GUID, no por nombre:

```powershell
$SCOPE_ID = az ad app show --id $API_APP --query "api.oauth2PermissionScopes[?value=='MCP.Access'] | [0].id" -o tsv
$ROLE_ID  = az ad app show --id $API_APP --query "appRoles[?value=='MCP.User'] | [0].id" -o tsv
```

**CLI (alternativa a A, B, C y D en una sola llamada).** Usa `$API_OBJ`, no `$API_APP`:

```powershell
$SCOPE_ID = [guid]::NewGuid().ToString(); $ROLE_ID = [guid]::NewGuid().ToString()
$app = @{
  identifierUris = @("api://$API_APP")
  api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes = @(@{ id = $SCOPE_ID; value = 'MCP.Access'; type = 'User'; isEnabled = $true
      adminConsentDisplayName = 'Acceder al MCP piloto como el usuario'; adminConsentDescription = 'Permite llamar al MCP piloto en nombre del usuario.'
      userConsentDisplayName = 'Acceder al MCP piloto'; userConsentDescription = 'Permite llamar al MCP piloto con tu identidad.' })
  }
  appRoles = @(@{ id = $ROLE_ID; value = 'MCP.User'; displayName = 'MCP User'; description = 'Usuarios autorizados a llamar al MCP piloto.'; allowedMemberTypes = @('User'); isEnabled = $true })
}
$app | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$env:TEMP\api-piloto.json" -Encoding utf8
az rest --method PATCH --headers Content-Type=application/json `
  --url "https://graph.microsoft.com/v1.0/applications/$API_OBJ" --body "@$env:TEMP\api-piloto.json"
Remove-Item "$env:TEMP\api-piloto.json"
```

**Comprobación:**

```powershell
az ad app show --id $API_APP --query "{uri:identifierUris[0], version:api.requestedAccessTokenVersion, scope:api.oauth2PermissionScopes[0].value, quien:api.oauth2PermissionScopes[0].type, rol:appRoles[?value=='MCP.User'] | [0].value, miembros:join(',', appRoles[?value=='MCP.User'] | [0].allowedMemberTypes)}" -o table
```

Resultado esperado: `api://<appId>`, `2`, `MCP.Access`, `User`, `MCP.User` y `User`. Si **falta la
columna `Version`**, la versión sigue en `null`, porque la salida en tabla oculta los valores vacíos.

### 3.3 Crear la aplicación empresarial

**Para qué:** sin la instancia en el tenant no se puede exigir la asignación, asignar el rol ni dar
el consentimiento. Al registrar la aplicación desde el portal, Entra **no siempre** la crea sola; en
la validación no la creó.

**Portal:** **Entra ID → Registros de aplicaciones →** `mcp-piloto-api` **→ Información general →
Aplicación administrada en el directorio local** → enlace para crear la entidad de servicio.

**CLI:** `$API_SP = az ad sp create --id $API_APP --query id -o tsv` (se pasa el `appId`).

**Comprobación:**

```powershell
az ad sp show --id $API_APP --query "{nombre:displayName, spId:id, asignacionRequerida:appRoleAssignmentRequired}" -o table
```

Resultado esperado: `spId` (el tercer identificador) y `asignacionRequerida` = `False`, que es el
valor por defecto.

### 3.4 Exigir asignación

**Para qué:** con *asignación requerida*, Entra **no emite token** a quien no tenga un rol asignado
(error `AADSTS50105`), y la petición nunca llega al MCP. Es defensa en profundidad: Entra y el MCP son
dos barreras independientes.

| | Asignación requerida = No | Asignación requerida = Sí |
|---|---|---|
| Usuario fuera del grupo | Token sin rol → el MCP responde 403 | **Sin token** (`AADSTS50105`) |
| Usuario del grupo | Acceso | Acceso |

**Portal:** **Entra ID → Aplicaciones empresariales →** `mcp-piloto-api` **→ Propiedades**:
- **¿Se requiere asignación?** = **Sí**.
- *¿Habilitado para que los usuarios inicien sesión?* = Sí. Si fuera No, nadie obtendría token.
- *¿Visible para los usuarios?* = No, opcional: oculta la API del portal *Mis aplicaciones*.

**CLI:**

```powershell
'{ "appRoleAssignmentRequired": true }' | Set-Content -LiteralPath "$env:TEMP\sp.json" -Encoding ascii
az rest --method PATCH --headers Content-Type=application/json `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP" --body "@$env:TEMP\sp.json"
Remove-Item "$env:TEMP\sp.json"
```

Desde aquí, **ni siquiera el administrador** obtiene token hasta que se completa el 3.5.

### 3.5 Asignar el rol `MCP.User` al grupo

**Para qué:** los miembros **directos** del grupo obtienen el token con `roles = MCP.User`. Desde ese
momento, dar o quitar acceso al MCP es añadir o quitar a alguien del grupo.

**Portal:** **Entra ID → Aplicaciones empresariales →** `mcp-piloto-api` **→ Usuarios y grupos →
+ Agregar usuario o grupo**:
- en *Usuarios y grupos* elige `MCP-Piloto` (el grupo, no los usuarios);
- en *Seleccionar un rol* debe aparecer `MCP User`. Si sale *Acceso predeterminado*, el rol no se
  guardó en el 3.2;
- pulsa **Asignar**.

**CLI:**

```powershell
@{ principalId = $GRUPO; resourceId = $API_SP; appRoleId = $ROLE_ID } | ConvertTo-Json |
  Set-Content -LiteralPath "$env:TEMP\rol.json" -Encoding ascii
az rest --method POST --headers Content-Type=application/json `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP/appRoleAssignedTo" --body "@$env:TEMP\rol.json"
Remove-Item "$env:TEMP\rol.json"
```

**Comprobación:**

```powershell
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP/appRoleAssignedTo" `
  --query "value[].{nombre:principalDisplayName, tipo:principalType, rol:appRoleId}" -o table
```

### 3.6 Guardar los identificadores en la ficha

**Para qué:** los pasos 4, 11 y 17, y la limpieza, los necesitan. Se leen de Entra, así que da igual
que se hayan creado por portal o por CLI, o que la consola sea nueva.

```powershell
$r = az ad app list --display-name 'mcp-piloto-api' --query "[0].{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$API_APP  = $r.appId; $API_OBJ = $r.objectId
$API_SP   = az ad sp show --id $API_APP --query id -o tsv
$SCOPE_ID = az ad app show --id $API_APP --query "api.oauth2PermissionScopes[?value=='MCP.Access'] | [0].id" -o tsv
$ROLE_ID  = az ad app show --id $API_APP --query "appRoles[?value=='MCP.User'] | [0].id" -o tsv
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
foreach ($p in @{ apiClientId = $API_APP; apiObjectId = $API_OBJ; apiServicePrincipalId = $API_SP; scopeId = $SCOPE_ID; userRoleId = $ROLE_ID }.GetEnumerator()) {
  $c.entra | Add-Member -Force -NotePropertyName $p.Key -NotePropertyValue $p.Value
}
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
(Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra | Format-List
```

`Add-Member -Force` crea el campo si no existe y lo sobrescribe si ya existe.

### 3.7 Comprobar que el token sale como espera el MCP

**Para qué:** validar ahora, sin esperar al agente, que Entra emite un token con `aud`, `iss` v2,
`scp` y **`roles`**. El rol solo aparece si la asignación al grupo funciona de verdad.

**Cómo se hace:** el conector aún no existe, así que se usa **Azure CLI** (`appId` fijo
`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) como cliente de prueba. Para que no pida consentimiento, se
**preautoriza temporalmente**.

Recargar las variables desde la ficha:

```powershell
$e = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra
$API_APP = $e.apiClientId; $API_OBJ = $e.apiObjectId; $SCOPE_ID = $e.scopeId
```

**a) Preautorizar Azure CLI.**

**Portal:** **Entra ID → Registros de aplicaciones →** `mcp-piloto-api` **→ Exponer una API →
+ Agregar una aplicación cliente** → `04b07795-8ddb-461a-bbee-02f9e1bf7b46`, marca `MCP.Access` →
**Agregar aplicación**.

**CLI:** lee la configuración `api` actual y la reescribe **completa**, para no perder el ámbito ni la
versión del token:

```powershell
$apiObj = az ad app show --id $API_APP --query api -o json | ConvertFrom-Json
$apiObj.preAuthorizedApplications = @(@{ appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'; delegatedPermissionIds = @($SCOPE_ID) })
@{ api = $apiObj } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$env:TEMP\api-preauth.json" -Encoding utf8
az rest --method PATCH --headers Content-Type=application/json `
  --url "https://graph.microsoft.com/v1.0/applications/$API_OBJ" --body "@$env:TEMP\api-preauth.json"
Remove-Item "$env:TEMP\api-preauth.json"
```

**b) Pedir el token y ver su contenido**, después de esperar entre 1 y 2 minutos a que se propague:

```powershell
$tok = az account get-access-token --scope "api://$API_APP/MCP.Access" --query accessToken -o tsv
$payload = $tok.Split('.')[1].Replace('-', '+').Replace('_', '/'); $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
$claims | Select-Object aud, iss, ver, scp, roles, azp, oid, upn | Format-List
```

Un JWT son tres trozos separados por puntos (cabecera, **contenido** y firma). Las líneas 2 y 3
descodifican el del medio.

| Error | Significa |
|---|---|
| `AADSTS50105` | No tienes el rol: la asignación al grupo no funciona o aún no se ha propagado |
| `AADSTS65001` | La preautorización no se ha aplicado o no se ha propagado |
| `AADSTS500011` | El `api://…` no existe |
| `iss` con `sts.windows.net` y `ver` `1.0` | La versión del token no es 2 |

**`upn` vacío es lo esperado:** en los tokens v2 es un campo **opcional**. Además, la documentación
avisa de que no es un identificador estable y **no debe usarse para autorizar**: se usa `oid`. Si el
MCP necesita mostrar el nombre del usuario, se añade en **Configuración del token →
Agregar notificación opcional → `upn`**.

**c) Retirar la preautorización**, para dejar la API como en producción.

**Portal:** **Exponer una API → Aplicaciones cliente autorizadas** → eliminar
`04b07795-8ddb-461a-bbee-02f9e1bf7b46`.

**CLI:** el mismo bloque de a) con `$apiObj.preAuthorizedApplications = @()`.

**Comprobación:**

```powershell
az ad app show --id $API_APP --query "{preautorizadas:length(api.preAuthorizedApplications), version:api.requestedAccessTokenVersion, ambito:api.oauth2PermissionScopes[0].value}" -o table
```

Resultado esperado: `0`, `2`, `MCP.Access`.

### Quién lo hace y qué acordar

- **Quién lo hace:** el administrador de aplicaciones de Entra.
- **Si su MCP ya tiene una aplicación en Entra**, se reutiliza: hay que revisar los cuatro puntos del
  3.2 y añadir el rol, la asignación obligatoria y el grupo.
- **La causa más común de 401** es que el MCP espere tokens v1 o valide otro emisor. La prueba del
  3.7 permite comprobarlo antes de montar el agente.


---

## Paso 4 de 18. Aplicación cliente OAuth del conector (Entra ID)

**Objetivo:** registrar la identidad con la que **el conector de Copilot Studio pide tokens en nombre
de cada usuario**.

| | API (`mcp-piloto-api`, Paso 3) | Cliente (`mcp-piloto-connector`, este paso) |
|---|---|---|
| Papel | Recibe y valida tokens | **Pide** tokens en nombre del usuario |
| En el token | `aud` (para quién es) | `azp` (quién lo pidió) |
| Qué comprueba el MCP | Que `aud` sea su `appId` | Que `azp` esté en su lista de clientes autorizados (`ALLOWED_CLIENT_IDS`, Paso 11) |
| URI de redirección | No | Sí (la *callback* del conector, Paso 17) |
| Secreto | No | Sí (Paso 17) |

**Por qué el MCP comprueba `azp`:** un token válido emitido para **otra aplicación** (como el de Azure
CLI del Paso 3.7) no sirve para llamar al MCP. Solo vale el que pide este conector.

Recarga de variables en una consola nueva:

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$e = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra
$API_APP = $e.apiClientId; $API_SP = $e.apiServicePrincipalId; $SCOPE_ID = $e.scopeId
```

### 4.1 Registrar la aplicación cliente

**Para qué:** su `appId` es el **Client ID** que se pone en el asistente MCP de Copilot Studio.

**Portal:** **Entra ID → Registros de aplicaciones → + Nuevo registro**:
- nombre `mcp-piloto-connector`;
- **Solo inquilino único**;
- **sin URI de redirección por ahora**: la *callback* la genera Copilot Studio en el Paso 17.

Después de registrarla:

```powershell
$r = az ad app list --display-name 'mcp-piloto-connector' --query "[0].{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$CLI_APP = $r.appId; $CLI_OBJ = $r.objectId
```

**CLI (alternativa):**

```powershell
$r = az ad app create --display-name 'mcp-piloto-connector' --sign-in-audience AzureADMyOrg --query "{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$CLI_APP = $r.appId; $CLI_OBJ = $r.objectId
```

### 4.2 Declarar el permiso `MCP.Access`

**Para qué:** el cliente declara **qué va a pedir**. Es la lista que el administrador aprobará en el 4.4.

**Portal:** **Entra ID → Registros de aplicaciones →** `mcp-piloto-connector` **→ Permisos de API**:
1. **Quita Microsoft Graph → User.Read** (… → *Quitar permiso*). El portal lo añade por defecto, pero el
   conector no lo usa: es el **principio de mínimo privilegio**.
2. **+ Agregar un permiso → Mis API →** `mcp-piloto-api` **→ Permisos delegados → MCP.Access → Agregar
   permisos**. *Delegados* significa que actúa en nombre del usuario; los permisos *de aplicación*
   serían para un servicio sin usuario.
3. **No concedas todavía el consentimiento** (se hace en el 4.4).

**CLI:** `az ad app permission add --id $CLI_APP --api $API_APP --api-permissions "$SCOPE_ID=Scope"`.
El aviso que muestra, pidiendo ejecutar `permission grant`, es esperado.

**Comprobación:**

```powershell
az ad app permission list --id $CLI_APP --query "[].{api:resourceAppId, permisos:join(',', resourceAccess[].id), tipo:join(',', resourceAccess[].type)}" -o table
```

Resultado esperado: **una sola fila**, con el `appId` de la API, el `scopeId` y `Scope`. Si aparece
`00000003-0000-0000-c000-000000000000` (Microsoft Graph), no se ha quitado `User.Read`.

### 4.3 Aplicación empresarial del cliente

**Para qué:** el consentimiento se guarda como una relación entre **dos aplicaciones empresariales**,
la del cliente y la de la API.

**Portal:** **Información general → Aplicación administrada en el directorio local** → crear.
**CLI:** `az ad sp create --id $CLI_APP --query id -o tsv`.
**Comprobación:** `az ad sp show --id $CLI_APP --query id -o tsv`.

### 4.4 Consentimiento de administrador (solo `MCP.Access`)

**Para qué:** autorizar **una vez, para toda la organización**, que este cliente pida `MCP.Access`.
- **Sin el consentimiento**, cada usuario vería una pantalla de consentimiento. Y si el tenant no
  permite que los usuarios consientan, la conexión fallaría con *aprobación del administrador
  necesaria*.
- **Con el consentimiento**, el conector no puede pedir nada más sin una nueva aprobación.

**Portal:** **Permisos de API → Conceder consentimiento de administrador para <tu-tenant> → Sí**. El estado
pasa a *Concedido para <tu-tenant>*.

**CLI:** `az ad app permission grant --id $CLI_APP --api $API_APP --scope MCP.Access`. Por defecto
concede para todos los usuarios (`AllPrincipals`).

**Comprobación:**

```powershell
az ad app permission list-grants --id $CLI_APP --query "[].{tipo:consentType, ambito:scope, recurso:resourceId}" -o table
```

Resultado esperado: **una sola fila**, `AllPrincipals`, `MCP.Access` y el SP de la API.

### 4.5 Guardar los identificadores en la ficha

**Para qué:**
- `connectorClientId` lo leen los scripts `set-connector-redirect.ps1` y `new-connector-secret.ps1`
  (Paso 17), y lo necesita `ALLOWED_CLIENT_IDS` del MCP (Paso 11).
- Los otros dos sirven para la limpieza.

```powershell
$r = az ad app list --display-name 'mcp-piloto-connector' --query "[0].{appId:appId, objectId:id}" -o json | ConvertFrom-Json
$CLI_APP = $r.appId; $CLI_OBJ = $r.objectId
$CLI_SP  = az ad sp show --id $CLI_APP --query id -o tsv
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
foreach ($p in @{ connectorClientId = $CLI_APP; connectorObjectId = $CLI_OBJ; connectorServicePrincipalId = $CLI_SP }.GetEnumerator()) {
  $c.entra | Add-Member -Force -NotePropertyName $p.Key -NotePropertyValue $p.Value
}
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
(Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra | Format-List
```

### Lo que falta en este cliente, y por qué ahora no

| Falta | Cuándo | Por qué no ahora |
|---|---|---|
| URI de redirección | Paso 17 | La genera Copilot Studio al crear el conector |
| Secreto | Paso 17 | Caduca: conviene crearlo justo antes de usarlo |
| Autorizarlo en el MCP (`ALLOWED_CLIENT_IDS`) | Paso 11 | El MCP aún no existe |

### Quién lo hace y qué acordar

- **Quién lo hace:** el administrador de aplicaciones de Entra. El consentimiento de administrador
  requiere Cloud Application Administrator o Application Administrator.
- **Qué entregar al equipo del MCP:** el `appId` de este cliente, para que lo añadan a su lista de
  clientes autorizados (`azp`). Si su MCP no comprueba `azp`, aceptaría tokens de cualquier
  aplicación con el permiso.


---

## Paso 5 de 18. Entorno de Power Platform y Managed Environment

**Objetivo:** crear el espacio de Power Platform donde vivirán el agente, el conector y las conexiones
de los usuarios. Puede ser un entorno **nuevo** o uno **existente**, con dos condiciones:

1. **Un entorno solo admite una Enterprise Policy**, y una política vinculada no se puede modificar.
   Si el entorno ya tiene una, hay que usar esa red o desvincularla.
2. **VNet Support solo funciona en Managed Environments.**

Un entorno existente **conserva su región**, lo que es útil si ya está en una geografía con VNet
Support (por ejemplo, *Europe*). En ese caso, salta al 5.3 para comprobarla y al 5.4 para activar
Managed Environment.

| Decisión | Por qué importa |
|---|---|
| **Región** | Fija las dos regiones de Azure de las VNets (Paso 12). Debe estar en la [tabla de VNet Support](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview#supported-regions) |
| **Tipo** | Espacio aislado (*Sandbox*) para desarrollo o pruebas; Producción para el servicio. Ocupa aproximadamente 1 GB de capacidad de Dataverse |
| **Grupo de seguridad** | `MCP-Piloto`: solo sus miembros entran. Es el segundo uso del grupo |
| **Dataverse** | Sí: Copilot Studio guarda en él el agente, el conector y las conexiones |

Recarga de variables en una consola nueva:

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$GRUPO = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra.pilotGroupObjectId
```

### 5.1 Comprobar la capacidad de Dataverse

**Para qué:** si no hay capacidad, la creación falla al cabo de varios minutos.

**Portal:** **Power Platform admin center → Licencias → Capacidad**. Debe quedar al menos 1 GB libre
en *Base de datos*.

### 5.2 Crear el entorno

**Portal:** **Power Platform admin center → Administrar → Entornos → + Nuevo**

| Campo | Valor | Para qué |
|---|---|---|
| Nombre | `MCP Piloto VNet` | — |
| Región | La geografía con VNet Support que corresponda (por ejemplo, **Europa**) | Si el tenant elige por **macrorregión**, la geografía la asigna Microsoft. La macrorregión *EU y EFTA* puede asignar Polonia, que no tiene VNet Support (ver «Regiones de la Unión Europea», al final de este paso). La validación se hizo en **Norteamérica**, que asignó Canadá |
| Obtener nuevas características antes | No | Evita versiones preliminares |
| Tipo | Espacio aislado | — |
| Dataverse | Sí | — |
| Pago por uso con Azure | No | — |
| Idioma, URL y moneda | Español, `mcp-piloto-vnet`, EUR | — |
| Aplicaciones de Dynamics 365 y datos de ejemplo | No | — |
| **Grupo de seguridad** | **Editar →** `MCP-Piloto` | Solo sus miembros entran al entorno |

**CLI:**

```powershell
pac admin create --name 'MCP Piloto VNet' --type Sandbox --macro-region <macrorregión> `
  --currency EUR --language 3082 --domain mcp-piloto-vnet --security-group-id $GRUPO
```

- `--macro-region`: `north-america`, `europe-uk`, `eu-efta`… (`pac admin create --help`). Si el tenant
  elige por región en lugar de macrorregión, usa `--region`.
- Tarda entre 5 y 15 minutos. La ayuda de `pac` confirma que `--security-group-id` admite grupos de
seguridad y grupos de Microsoft 365.

### 5.3 Comprobar dónde se ha creado

**Para qué:** la región real decide las VNets del Paso 12.

```powershell
$ENV_ID = (pac admin list --json | ConvertFrom-Json | Where-Object DisplayName -eq 'MCP Piloto VNet').EnvironmentId
pac environment-management get-environment-by-id-for-user --environment $ENV_ID --json | ConvertFrom-Json |
  Select-Object displayName, type, geo, azureRegion, url, securityGroupId, protectionLevel, state | Format-List
```

| `geo` | Regiones de las VNets | Ubicación de la Enterprise Policy |
|---|---|---|
| `canada` | `canadacentral`, `canadaeast` | `canada` |
| `unitedstates` | `eastus`, `westus` | `unitedstates` |
| `europe` | `westeurope`, `northeurope` | `europe` |

**Afinidad de macrorregión:** en los tenants con macrorregiones, el **primer** entorno de una
macrorregión fija la geografía de los siguientes. Si ya existe un entorno en esa macrorregión, el
nuevo caerá en la misma geografía.

### 5.4 Activar Managed Environment

**Para qué:** VNet Support lo exige. Sin esto no se puede vincular la Enterprise Policy (Paso 16).
Además activa controles de gobierno.

**Portal:** **Administrar → Entornos →** marca `MCP Piloto VNet` **→ Habilitar entornos
administrados** → valores por defecto → **Habilitar**.

**CLI:** `pac admin set-governance-config --environment $ENV_ID --protection-level Standard`
(`Standard` lo activa y `Basic` lo desactiva).

**Comprobación:** en la salida del 5.3, `protectionLevel` = `Standard`.

### 5.5 Guardar en la ficha

**Para qué:**
- `environmentId` y `regions` los usa `pp-vnet-diagnostics.ps1` (Paso 16).
- `orgUrl` lo usa `grant-connector-access.ps1` (Paso 18).
- `regions` y `policyLocation` deciden las VNets (Paso 12) y la ubicación de la política (Paso 15).

```powershell
$entorno = pac environment-management get-environment-by-id-for-user --environment $ENV_ID --json | ConvertFrom-Json
$REGIONES = switch ($entorno.geo) { 'canada' { @('canadacentral', 'canadaeast') } 'unitedstates' { @('eastus', 'westus') } 'europe' { @('westeurope', 'northeurope') } default { @() } }
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
$c.powerPlatform.environmentId = $entorno.id
$c.powerPlatform.orgUrl = $entorno.url.TrimEnd('/')
$c.powerPlatform.regions = $REGIONES
$c.powerPlatform | Add-Member -Force -NotePropertyName policyLocation -NotePropertyValue $entorno.geo
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
(Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).powerPlatform | Format-List
```

La variable se llama `$entorno` y no `$env` para no mezclarla con `$env:`, que es como PowerShell
accede a las variables de entorno.

### Regiones de la Unión Europea

Está explicado en detalle en la sección **3.0.4** del README. En resumen:

| Geografía | VNets | Valoración |
|---|---|---|
| **Europe** | `westeurope` + `northeurope` | ✅ Recomendada: ninguna región restringida |
| France | `francecentral` + `francesouth` | ⚠️ France South restringida (requiere solicitar acceso) |
| Germany | `germanywestcentral` + `germanynorth` | ⚠️ Germany North restringida |
| Sweden / Italy | `swedencentral` / `italynorth` | ✅ Una sola región |
| **Poland** | — | ❌ Sin VNet Support |

- En los tenants con **macrorregiones**, la macrorregión *EU y EFTA* puede asignar **Polonia**. Para
  elegir una región concreta hace falta **ADR**.
- **Los entornos que ya existen conservan su región:** uno que ya esté en *Europe* sirve; basta con
  activar Managed Environment.
- Qué comprobar antes de empezar:
  - `locationSelectionMode`;
  - la geografía (`geo`) del entorno que se vaya a usar;
  - si tienen ADR;
  - una VNet vacía de prueba en las dos regiones, porque la lista de regiones de la suscripción no
    detecta todos los bloqueos. En la validación, una suscripción recibió `locationineligible` en West
    Europe aunque la región aparecía en la lista.
- El hub, la VPN y el MCP pueden estar en cualquier región de la UE, incluida Spain Central: solo las
  VNets delegadas dependen de la geografía del entorno.


---

## Paso 6 de 18. VNet hub de Azure y `GatewaySubnet` (crear o revisar)

> 🔍 **Si ya existe, revísalo** con las consultas; **si no, créalo** con el apartado *Cómo se crea desde cero*.

**Objetivo:** entender por qué las subredes de Power Platform llegan a la VPN **a través de una red
central (hub)**, y comprobar que el hub cumple las reglas.

```
Subred PP Canada Central ─┐                     ┌─ túnel 1 ─┐
                          ├─ peering ─► HUB ─► VPN Gateway   ├─► HA VPN de GCP ─► MCP
Subred PP Canada East  ───┘   (gateway transit)  └─ túnel 2 ─┘
```

| Concepto | Qué es | Por qué hace falta |
|---|---|---|
| **Hub** (`<vnet-hub>`) | Red central de Azure | Una sola VPN sirve a todas las redes conectadas (por ejemplo, las de varios entornos de Power Platform) |
| **`GatewaySubnet`** | Subred reservada para el VPN Gateway | Azure solo despliega el gateway en una subred con ese nombre exacto |
| **Peering** | Conexión privada entre dos VNets | Une cada subred de Power Platform con el hub, aunque estén en regiones distintas |
| ***Gateway transit*** | Opción del peering | Las VNets conectadas usan el VPN Gateway del hub. Sin ella, el tráfico llega al hub pero no entra en la VPN |

### 6.1 Red hub

**Portal:** **Redes virtuales →** `<vnet-hub>` **→ Información general / Espacio de direcciones**

```powershell
$RG = '<rg-hub>'
az network vnet show -g $RG -n <vnet-hub> --query "{nombre:name, region:location, espacio:join(',', addressSpace.addressPrefixes), dns:join(',', dhcpOptions.dnsServers)}" -o table
```

| Campo | Valor | Qué significa |
|---|---|---|
| `region` | `northeurope` | El hub puede estar en otra región que las subredes de Power Platform: el peering global los une. Solo las subredes delegadas dependen de la geografía del entorno |
| `espacio` | `10.91.0.0/16` | Se anuncia a GCP por BGP. No debe solaparse con ninguna otra red |
| `dns` | Vacío | Usa el DNS de Azure (`168.63.129.16`), que resuelve las zonas privadas enlazadas |

### 6.2 Subredes

**Portal:** **Redes virtuales →** `<vnet-hub>` **→ Subredes**

```powershell
az network vnet subnet list -g $RG --vnet-name <vnet-hub> --query "[].{subred:name, prefijo:addressPrefix, delegada:join(',', delegations[].serviceName), nsg:networkSecurityGroup.id != null, tablaRutas:routeTable.id != null}" -o table
```

Resultado: debe existir **`GatewaySubnet`** (en el ejemplo, `10.91.255.0/27`), sin NSG ni tabla de rutas.
El hub puede tener otras subredes (servidores, Private Resolver, firewall…).

**Reglas de la `GatewaySubnet`**
([documentación oficial](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings)):

| Regla | Por qué |
|---|---|
| Nombre exactamente `GatewaySubnet` | Azure busca ese nombre para desplegar el gateway |
| `/27` o mayor | Tamaño recomendado: el gateway usa varias IP (instancias, actualizaciones) |
| Sin NSG | No soportado: puede cortar el tráfico de control del gateway |
| Sin rutas `0.0.0.0/0` | No soportado: desviaría el tráfico del gateway |
| Nada más dentro | Es exclusiva del gateway |

### 6.3 Peerings del hub

**Portal:** **Redes virtuales →** `<vnet-hub>` **→ Emparejamientos**

```powershell
az network vnet peering list -g $RG --vnet-name <vnet-hub> -o json | ConvertFrom-Json |
  Select-Object @{n='peering';e={$_.name}}, @{n='estado';e={$_.peeringState}}, @{n='transitoGateway';e={$_.allowGatewayTransit}}, @{n='usaGatewayRemoto';e={$_.useRemoteGateways}}, @{n='redRemota';e={$_.remoteVirtualNetwork.id.Split('/')[-1]}} | Format-Table -AutoSize
```

Si el hub ya da servicio a otras VNets, verás sus peerings, `Connected` y con `transitoGateway = True`.

- En el lado del hub, **`transitoGateway = True`** significa que el hub **ofrece** su gateway.
- En el lado de la VNet de Power Platform, **`usaGatewayRemoto = True`** significa que la red **usa** ese
  gateway.
- Hacen falta las dos mitades.

**Para el Paso 13:** anota los nombres de peering que ya existen. Los nuevos deben tener nombres
distintos (en la guía, `to-piloto-pp-*`).

### Cómo se crea desde cero

**Portal:**
1. **Redes virtuales → + Crear**: región y espacio (por ejemplo, `10.91.0.0/16`).
2. Después, **Subredes → + Subred de puerta de enlace**. El portal la llama `GatewaySubnet`; usa `/27`.

**CLI:**

```powershell
az network vnet create -g <grupo-recursos> -n <nombre-hub> -l <región> --address-prefixes 10.91.0.0/16
az network vnet subnet create -g <grupo-recursos> --vnet-name <nombre-hub> -n GatewaySubnet --address-prefixes 10.91.255.0/27
```

| Decisión | Recomendación |
|---|---|
| Región del hub | Cualquiera de la UE (incluida Spain Central), cerca del MCP o del centro de datos |
| Rango | Libre, sin solapes con GCP, on-premises ni Power Platform |
| ¿Hub nuevo o existente? | Si ya hay un hub con VPN o ExpressRoute, se reutiliza: solo faltan los peerings con *gateway transit* |
| DNS | Si usan DNS corporativo o Private Resolver, las VNets de Power Platform deben tenerlo **antes** de vincular la política |


---

## Paso 7 de 18. VPN Gateway de Azure con BGP (crear o revisar)

> 🔍 **Si ya existe, revísalo** con las consultas; **si no, créalo** con el apartado *Cómo se crea desde cero*.

**Objetivo:** entender el **extremo de Azure** de los túneles IPsec hacia GCP:
- cifra y descifra el tráfico del hub hacia Google y el de vuelta;
- habla **BGP** con el Cloud Router de Google.

**BGP:** es el protocolo con el que los dos routers se cuentan qué redes tienen detrás.
- Azure anuncia `10.91.0.0/16` y las subredes de Power Platform.
- Google anuncia `10.95.0.0/24` y `10.96.0.10/32`.
- Sin BGP habría que mantener las rutas a mano. Con BGP, Google aprende **solo** las VNets de
  Power Platform cuando se conectan (Paso 13).

| Concepto | Qué es |
|---|---|
| **ASN** | Identidad de cada router BGP. Los dos extremos deben tener ASN distintos: Azure `65515` y GCP `64514` |
| **APIPA** (`169.254.x.x`) | Direcciones internas de cada túnel por las que hablan los routers. No se enrutan |

### 7.1 Propiedades del gateway

**Portal:** **Puertas de enlace de red virtual →** `<vpn-gateway>` **→ Información general / Configuración**

```powershell
$RG = '<rg-hub>'
az network vnet-gateway show -g $RG -n <vpn-gateway> --query "{nombre:name, region:location, tipo:gatewayType, vpn:vpnType, sku:sku.name, generacion:vpnGatewayGeneration, activoActivo:activeActive, bgp:enableBgp, asn:bgpSettings.asn, estado:provisioningState}" -o table
```

| Campo | Valor | Por qué |
|---|---|---|
| `tipo` / `vpn` | `Vpn` / `RouteBased` | `RouteBased` es obligatorio para BGP y para la HA VPN de Google |
| `sku` | `VpnGw1AZ` | El SKU más pequeño con BGP y redundancia de zona (hasta 30 túneles, unos 650 Mbps). `Basic` no admite BGP |
| `activoActivo` | `False` | En la validación: **activo-pasivo**, con una IP pública (simplificación) |
| `bgp` / `asn` | `True` / `65515` | ASN por defecto de Azure. Azure reserva `65515` y del `65517` al `65520` |

> ⚠️ La [guía de Google](https://cloud.google.com/network-connectivity/docs/vpn/tutorials/create-ha-vpn-connections-google-cloud-azure)
> usa **activo-activo** (dos IP públicas) para el SLA del 99,99 %. **Recomendado en producción.**

### 7.2 Direcciones BGP

**Portal:** **Configuración →** apartado **BGP**

```powershell
az network vnet-gateway show -g $RG -n <vpn-gateway> --query "bgpSettings.bgpPeeringAddresses[].{ipConfig:ipconfigurationId, apipa:join(',', customBgpIpAddresses), porDefecto:join(',', defaultBgpIpAddresses), tunelIp:join(',', tunnelIpAddresses)}" -o json | ConvertFrom-Json | ForEach-Object { $_.ipConfig = $_.ipConfig.Split('/')[-1]; $_ } | Format-Table -AutoSize
```

| Campo | Valor | Qué es |
|---|---|---|
| `apipa` | `169.254.21.1,169.254.22.1` | Las direcciones BGP de Azure, una por túnel. Google usa `.21.2` y `.22.2` |
| `porDefecto` | `10.91.255.30` | Dirección BGP automática de la `GatewaySubnet`; no se usa con Google |
| `tunelIp` | `<AZURE_VPNGW_IP>` | La IP pública: el destino de los túneles |

- Google exige direcciones *link-local*, y Azure solo admite APIPA propias entre `169.254.21.0` y
  `169.254.22.255` ([documentación](https://learn.microsoft.com/en-us/azure/vpn-gateway/bgp-howto)).
- Con APIPA, **Azure no inicia la sesión BGP**: la inicia Google. Si los túneles están arriba y BGP no,
  hay que revisar la configuración del lado de Google.

### 7.3 IP pública

**Portal:** **Direcciones IP públicas →** `<ip-publica-vpngw>`

```powershell
az network public-ip show -g $RG -n <ip-publica-vpngw> --query "{nombre:name, ip:ipAddress, sku:sku.name, asignacion:publicIPAllocationMethod, zonas:join(',', zones)}" -o table
```

- `<AZURE_VPNGW_IP>`, `Standard`, `Static` y zonas `1,2,3`. Lo exige el SKU `AZ`, y al ser estática
  Google puede tenerla configurada.
- Que la IP sea pública **no expone el MCP**: solo acepta túneles IPsec con la clave compartida.

### Cómo se crea desde cero

**Coste:** unos 0,21 USD/hora (unos 5 USD/día) en North Europe, según la API de precios de Azure. Tarda
entre 30 y 45 minutos.

**Portal:** **Puertas de enlace de red virtual → + Crear**:
- tipo **VPN**;
- SKU **VpnGw1AZ** o superior;
- la red virtual del hub;
- IP pública **Standard**;
- **activo-activo habilitado** (segunda IP);
- **BGP** con un ASN distinto del de GCP;
- **APIPA personalizadas**: las acordadas con GCP.

**CLI** (la plantilla del repositorio es activo-pasivo y habría que adaptarla para activo-activo):

```powershell
az deployment group create -g <grupo-recursos> -n vpn-gateway --template-file infra\vpn-gateway.bicep `
  --parameters location=<región> vnetName=<nombre-hub> gatewayName=<nombre-gateway> `
  --query properties.outputs.publicIp.value -o tsv
```

**Qué acordar con el equipo de GCP:**
- los ASN (distintos entre sí);
- las APIPA de cada túnel;
- las IP públicas de Azure;
- la clave compartida, siempre **por un canal seguro**.


---

## Paso 8 de 18. Red de GCP: VPC, subred y endpoint PSC (crear o revisar)

> 🔍 **Si ya existe, revísalo** con las consultas; **si no, créalo** con el apartado *Cómo se crea desde cero*.

**El problema:** Cloud Run **no tiene IP privada**. Con *ingress* `internal`, rechaza las peticiones de
Internet y solo acepta las que entran por la red privada de GCP.

**La solución de Google**
([Cloud Run private networking](https://cloud.google.com/run/docs/securing/private-networking)) tiene
tres piezas:

| Pieza | Qué es | Paso |
|---|---|---|
| Endpoint PSC para las API de Google | IP privada de la VPC (`10.96.0.10`) que da acceso a los servicios de Google, incluido Cloud Run. Lo que entra por ella es **interno** | Este paso |
| Zona DNS privada con el nombre `run.app` | Desde Azure, la URL del MCP resuelve a `10.96.0.10` | Paso 14 |
| Ruta hacia el endpoint | Cloud Router anuncia `10.96.0.10/32` a Azure por BGP | Paso 9 |

Se conserva la URL `run.app` con su certificado de **Google Trust Services (CA pública)**, que es lo
que exige Power Platform.

### 8.1 VPC

**Consola:** **Red de VPC → Redes de VPC →** `<vpc-gcp>`

```powershell
$PJ = '<GCP_PROJECT_ID>'
gcloud compute networks describe <vpc-gcp> --project $PJ --format="table(name,autoCreateSubnetworks,routingConfig.routingMode,mtu)"
```

| Campo | Valor | Por qué |
|---|---|---|
| `AUTO_CREATE_SUBNETWORKS` | `False` | Modo personalizado. El modo automático crearía `10.128.0.0/9`, que podría solaparse con Azure |
| `ROUTING_MODE` | `GLOBAL` | Las rutas aprendidas de Azure valen en todas las regiones de la VPC |

### 8.2 Subred

**Consola:** **Redes de VPC →** `<vpc-gcp>` **→ Subredes**

```powershell
gcloud compute networks subnets describe <subred-gcp> --region europe-west1 --project $PJ --format="table(name,ipCidrRange,privateIpGoogleAccess,region.basename())"
```

- `10.95.0.0/24` en `europe-west1`, con Private Google Access = `True`.
- Private Google Access lo necesitan las **VM de la VPC sin IP pública** para usar el endpoint. El
  tráfico que llega desde Azure no lo necesita.
- Cloud Run no vive en la subred. Con un F5 o un balanceador interno, en cambio, los MCP **sí** estarán en
  subredes.

### 8.3 Endpoint PSC

**Consola:** **Servicios de red → Private Service Connect → Extremos conectados →** `<psc>`

```powershell
gcloud compute addresses describe <psc>-ip --global --project $PJ --format="table(name,address,purpose,addressType,network.basename())"
gcloud compute forwarding-rules describe <psc> --global --project $PJ --format="table(name,IPAddress,target,network.basename())"
gcloud services list --enabled --project $PJ --filter="config.name:(compute.googleapis.com OR servicedirectory.googleapis.com OR dns.googleapis.com OR run.googleapis.com)" --format="value(config.name)"
```

- **Dirección `<psc>-ip`:** `10.96.0.10`, `PRIVATE_SERVICE_CONNECT`, `INTERNAL`. Está fuera de la
  subred para no solaparse.
- **Regla `<psc>`:** `10.96.0.10` → `all-apis`, que incluye Cloud Run.

**Requisitos** ([documentación](https://cloud.google.com/vpc/docs/configure-private-service-connect-apis)):

| Requisito | Por qué |
|---|---|
| API Compute, Service Directory y Cloud DNS activas | El endpoint se registra en Service Directory y crea zonas de Cloud DNS. **Por eso hicieron falta los roles `servicedirectory.editor` y `dns.admin`** |
| Nombre de 1 a 20 caracteres, solo minúsculas y números, empezando por letra | Por eso se llama `<psc>` |
| No accesible desde VPC emparejadas | Sí desde VPN o Interconnect si hay ruta (Paso 9) |

### 8.4 Firewall

```powershell
gcloud compute firewall-rules list --project $PJ --filter="network~<vpc-gcp>" --format="table(name,direction,sourceRanges.list())"
```

**Con Cloud Run no hacen falta reglas:** no hay VM, y el tráfico va a un servicio gestionado de Google
a través del endpoint PSC. **Con MCP en VM o detrás de un F5 sí hacen falta:** TCP 443 desde las
subredes de Power Platform hacia la VIP del MCP o del F5.

### Cómo se crea desde cero

```powershell
gcloud services enable compute.googleapis.com servicedirectory.googleapis.com dns.googleapis.com --project <proyecto>
gcloud compute networks create <vpc> --subnet-mode=custom --bgp-routing-mode=global --project <proyecto>
gcloud compute networks subnets create <subred> --network=<vpc> --region=<región> --range=<rango> --enable-private-ip-google-access --project <proyecto>
gcloud compute addresses create <nombre>-ip --global --purpose=PRIVATE_SERVICE_CONNECT --addresses=<IP-libre> --network=<vpc> --project <proyecto>
gcloud compute forwarding-rules create <nombre> --global --network=<vpc> --address=<nombre>-ip --target-google-apis-bundle=all-apis --project <proyecto>
```

Es la parte de red de `infra/gcp/setup-gcp-network.ps1`, que además crea la VPN y necesita la IP del
gateway de Azure.

### Qué cambia si el MCP no es Cloud Run (F5 o balanceador interno)

| | Cloud Run (ejemplo de la guía) | F5 o balanceador interno en la VPC |
|---|---|---|
| IP privada del MCP | Endpoint PSC `10.96.0.10` | VIP del F5 |
| Endpoint PSC | Necesario | **No hace falta** |
| DNS | Zona privada de Azure con el nombre `run.app` exacto | El nombre del MCP debe resolver a la VIP desde Azure (Private Resolver con reenvío a Cloud DNS, o una zona privada) |
| Certificado | El de Google (CA pública) | **El F5 debe presentar uno de CA pública** |
| Firewall de GCP | Ninguno | **TCP 443 desde las subredes de Power Platform** |
| Qué anuncia Cloud Router | Subred + IP del PSC | La subred de la VIP |


---

## Paso 9 de 18. HA VPN y Cloud Router de GCP (crear o revisar)

> 🔍 **Si ya existe, revísalo** con las consultas; **si no, créalo** con el apartado *Cómo se crea desde cero*.

| Pieza de GCP | Equivale en Azure a | Qué hace |
|---|---|---|
| **HA VPN** (`<ha-vpn>`) | VPN Gateway (parte IPsec) | Extremo de los túneles. Tiene dos interfaces con dos IP públicas |
| **Cloud Router** (`<cloud-router>`) | VPN Gateway (parte BGP) | Anuncia las redes de GCP y aprende las de Azure |
| **Gateway externo** (`<gw-externo-azure>`) | Gateway de red local (Paso 10) | Describe dentro de GCP el otro extremo (Azure) |

```
            GCP                                      Azure
HA VPN  interfaz 0 (<GCP_HAVPN_IP_0>)   ── túnel 0 ──┐
        interfaz 1 (<GCP_HAVPN_IP_1>) ── túnel 1 ──┴─► VPN Gateway <AZURE_VPNGW_IP>
Cloud Router ASN 64514  ◄──── BGP por cada túnel ────►  ASN 65515
```

### 9.1 HA VPN

**Consola:** **Conectividad de red → VPN → Puertas de enlace de Cloud VPN →** `<ha-vpn>`

```powershell
$PJ = '<GCP_PROJECT_ID>'
gcloud compute vpn-gateways describe <ha-vpn> --region europe-west1 --project $PJ --format="table(name,network.basename(),stackType,vpnInterfaces[].ipAddress.list())"
```

- Dos IP (`<GCP_HAVPN_IP_0>` y `<GCP_HAVPN_IP_1>`), una por interfaz. Google las asigna de grupos distintos.
- `IPV4_ONLY`.
- HA VPN da un **SLA del 99,99 %** (Classic VPN, 99,9 %), siempre que haya un túnel desde cada
  interfaz.

### 9.2 Gateway externo

**Consola:** **VPN → Puertas de enlace de VPN de intercambio de tráfico →** `<gw-externo-azure>`

```powershell
gcloud compute external-vpn-gateways describe <gw-externo-azure> --project $PJ --format="table(name,redundancyType,interfaces[].ipAddress.list())"
```

- `SINGLE_IP_INTERNALLY_REDUNDANT` con `<AZURE_VPNGW_IP>`: Azure activo-pasivo, con una sola IP.
  Según Google, da el 99,99 % en su lado
  ([topologías](https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies)).
- Con Azure **activo-activo** sería **`TWO_IPS_REDUNDANCY`**, con las dos IP.

### 9.3 Cloud Router

**Consola:** **Conectividad de red → Cloud Router →** `<cloud-router>`

```powershell
gcloud compute routers describe <cloud-router> --region europe-west1 --project $PJ --format="table(name,network.basename(),bgp.asn,bgp.advertiseMode,bgp.advertisedGroups.list(),bgp.advertisedIpRanges[].range.list())"
```

| Valor | Por qué |
|---|---|
| ASN `64514` | Cloud Router exige un ASN privado (`64512`-`65534` o `4200000000`-`4294967294`), distinto del de Azure ([documentación](https://cloud.google.com/network-connectivity/docs/router/how-to/create-router-vpc-network)) |
| `CUSTOM` | Hace falta para anunciar algo más que las subredes |
| `ALL_SUBNETS` | Azure aprende `10.95.0.0/24` |
| **`10.96.0.10/32`** | **Imprescindible:** el endpoint PSC no está en ninguna subred, y sin este anuncio Azure no tendría ruta hacia el MCP |

En sentido contrario, el Cloud Router **aprende** las redes de Azure para que las respuestas vuelvan
por la VPN (Paso 10).

### Cómo se crea desde cero

```powershell
gcloud compute vpn-gateways create <havpn> --network=<vpc> --region=<región> --stack-type=IPV4_ONLY --project <proyecto>
gcloud compute routers create <router> --network=<vpc> --region=<región> --asn=<ASN-privado> `
  --advertisement-mode=custom --set-advertisement-groups=all_subnets --set-advertisement-ranges=<IP-PSC>/32 --project <proyecto>
gcloud compute external-vpn-gateways create <gw-azure> --interfaces=0=<IP-pública-Azure> --project <proyecto>
# Azure activo-activo: --interfaces=0=<IP1>,1=<IP2>
```

**Consola:** **VPN → Crear conexión VPN → VPN de alta disponibilidad**: el asistente crea la HA VPN, el
gateway de intercambio de tráfico, los túneles y el Cloud Router.

**Con un F5**, se anuncia la subred de la VIP y no hace falta el PSC. **Si la organización usa Cross-Cloud
Interconnect**, sustituye a la VPN, con el mismo modelo de BGP y de anuncios.


---

## Paso 10 de 18. Túneles IPsec y sesiones BGP, Azure ↔ GCP (crear o revisar)

> 🔍 **Si ya existe, revísalo** con las consultas; **si no, créalo** con el apartado *Cómo se crea desde cero*.

| Capa | Qué es | Si falla |
|---|---|---|
| **Túnel IPsec** | Canal cifrado entre una IP pública de Azure y una de GCP, autenticado con la clave compartida (PSK) | No pasa tráfico |
| **Sesión BGP** | Conversación entre los routers, dentro del túnel, con direcciones APIPA | El túnel está arriba, pero nadie sabe qué redes hay detrás |
| **Rutas** | Qué redes de un lado conoce el otro | El tráfico hacia la red que falta no entra en la VPN |

Hay dos túneles, uno por interfaz de la HA VPN, **los dos activos**.

### Lado de GCP

**Túneles.** **Consola:** **VPN → Túneles de Cloud VPN**

```powershell
$PJ = '<GCP_PROJECT_ID>'
gcloud compute vpn-tunnels list --project $PJ --filter="name~<prefijo-tuneles>" --format="table(name,vpnGatewayInterface,peerExternalGatewayInterface,ikeVersion,status,detailedStatus)"
```

Resultado: `tunnel0` (interfaz de GCP 0 → interfaz de Azure 0) y `tunnel1` (GCP 1 → Azure 0), con
IKEv2 y `ESTABLISHED`. Con Azure activo-activo, el túnel 1 iría a la interfaz 1 de Azure.

**Sesiones BGP (configuración).** **Consola:** **Cloud Router →** `<cloud-router>` **→ Sesiones de BGP**

```powershell
gcloud compute routers describe <cloud-router> --region europe-west1 --project $PJ --flatten="bgpPeers[]" --format="table(bgpPeers.name:label=SESION_BGP,bgpPeers.interfaceName:label=INTERFAZ,bgpPeers.ipAddress:label=IP_GCP,bgpPeers.peerIpAddress:label=IP_AZURE,bgpPeers.peerAsn:label=ASN_AZURE)"
```

Resultado: `169.254.21.2` ↔ `169.254.21.1` y `169.254.22.2` ↔ `169.254.22.1`, con ASN 65515. Hay un
`/30` por túnel.

**Estado y rutas aprendidas de Azure:**

```powershell
gcloud compute routers get-status <cloud-router> --region europe-west1 --project $PJ --flatten="result.bgpPeerStatus[]" --format="table(result.bgpPeerStatus.name:label=SESION_BGP,result.bgpPeerStatus.status:label=ESTADO,result.bgpPeerStatus.uptime:label=ACTIVA_DESDE,result.bgpPeerStatus.numLearnedRoutes:label=RUTAS_APRENDIDAS)"
gcloud compute routers get-status <cloud-router> --region europe-west1 --project $PJ --flatten="result.bestRoutes[]" --format="table(result.bestRoutes.destRange:label=RED_DE_AZURE,result.bestRoutes.nextHopIp:label=SIGUIENTE_SALTO,result.bestRoutes.priority:label=PRIORIDAD)"
```

Resultado esperado: dos sesiones `UP`. El hub (`10.91.0.0/16`) y las redes de Azure que ya usen el
hub aparecen por los dos túneles con prioridad 0.
- **ECMP:** el tráfico se reparte entre los dos túneles y, si uno cae, sigue por el otro.
- GCP conoce las subredes de Power Platform gracias al ***gateway transit*** (Paso 6).
- **En el Paso 13 deberán aparecer `10.97.0.0/24` y `10.98.0.0/24`**, sin tocar nada en GCP.

### Lado de Azure

**Gateways de red local.** **Portal:** **Puertas de enlace de red local**

```powershell
$RG = '<rg-hub>'
az network local-gateway list -g $RG --query "[].{nombre:name, ipPublicaGcp:gatewayIpAddress, asn:bgpSettings.asn, ipBgpGcp:bgpSettings.bgpPeeringAddress, prefijos:join(',', localNetworkAddressSpace.addressPrefixes)}" -o table
```

Resultado: `gcp-if0` (`<GCP_HAVPN_IP_0>`, `169.254.21.2`) y `gcp-if1` (`<GCP_HAVPN_IP_1>`,
`169.254.22.2`), los dos con ASN 64514. Que no tengan **prefijos** es correcto: con BGP no se escriben
a mano.

**Conexiones.** **Portal:** **Puertas de enlace de red virtual →** `<vpn-gateway>` **→ Conexiones**

```powershell
az network vpn-connection list -g $RG --query "[].{nombre:name, tipo:connectionType, protocolo:connectionProtocol, bgp:enableBgp, apipaAzure:join(',', gatewayCustomBgpIpAddresses[].customBgpIpAddress)}" -o table
foreach ($c in '<conexion>-0','<conexion>-1') { "{0}: {1}" -f $c, (az network vpn-connection show -g $RG -n $c --query connectionStatus -o tsv) }
```

Resultado: dos conexiones IPsec IKEv2 con BGP, APIPA `.21.1` y `.22.1`, `Connected`. La clave
compartida no se muestra en ninguna consulta.

**BGP y rutas.** **Portal:** **Puertas de enlace de red virtual →** `<vpn-gateway>` **→ Pares BGP**

```powershell
az network vnet-gateway list-bgp-peer-status -g $RG -n <vpn-gateway> --query "value[].{vecino:neighbor, asn:asn, estado:state, rutasRecibidas:routesReceived, conectadoDesde:connectedDuration}" -o table
az network vnet-gateway list-learned-routes -g $RG -n <vpn-gateway> --query "value[?origin=='EBgp'].{red:network, siguienteSalto:nextHop, asPath:asPath}" -o table
az network vnet-gateway list-advertised-routes -g $RG -n <vpn-gateway> --peer 169.254.21.2 --query "value[].network" -o tsv
```

Resultado:
- Dos pares `Connected`, con 2 rutas recibidas cada uno.
- **Rutas aprendidas:** `10.95.0.0/24` y **`10.96.0.10/32`** (gracias al anuncio personalizado del
  Paso 9), con *AS path* `64514`.
- **Rutas anunciadas:** `10.91.0.0/16` y las redes de Azure que ya usen el hub.

### Cómo se crea desde cero

**Orden:** gateways → clave compartida → túneles y BGP en GCP → gateways de red local y conexiones en
Azure.

```powershell
# GCP, por cada túnel (en el túnel 1: --interface=1 y 169.254.22.2 / 169.254.22.1)
gcloud compute vpn-tunnels create <tunel0> --region=<región> --vpn-gateway=<havpn> --interface=0 `
  --peer-external-gateway=<gw-azure> --peer-external-gateway-interface=0 --shared-secret=<PSK> --router=<router> --ike-version=2
gcloud compute routers add-interface <router> --region=<región> --interface-name=<tunel0>-if --ip-address=169.254.21.2 --mask-length=30 --vpn-tunnel=<tunel0>
gcloud compute routers add-bgp-peer <router> --region=<región> --peer-name=<tunel0>-peer --interface=<tunel0>-if --peer-ip-address=169.254.21.1 --peer-asn=65515
```

En Azure lo hace `infra\vpn-gcp-connections.bicep` (ver 2C.4 del README). En el portal:
- **Puertas de enlace de red local → + Crear**: IP de GCP, *Configurar BGP*, ASN y dirección BGP.
- **Conexiones → + Agregar**: sitio a sitio, con la clave compartida, *Habilitar BGP* y la APIPA
  personalizada.

**Clave compartida:** aleatoria, larga e intercambiada por un **canal seguro**, nunca por correo. Que no
quede en el historial de comandos.

| Síntoma | Causa habitual |
|---|---|
| Túnel no establecido | Clave distinta, IP equivocada o IKE distinto |
| Túnel arriba y BGP abajo | APIPA o ASN cruzados. Con APIPA, Azure no inicia la sesión: revisa GCP |
| BGP arriba y falta una red | Falta el anuncio personalizado en GCP o el *gateway transit* en Azure |


---

## Paso 11 de 18. MCP de prueba en Cloud Run

**Objetivo:** desplegar un servidor MCP **de prueba** al que llamará el agente. Sirve para validar
toda la cadena (red privada, DNS, certificado y token) antes de conectar los MCP reales. Usa el
servidor de ejemplo del repositorio ([src/](../src/)), configurado con **tu** API y **tu** conector.

**La imagen:** el README explica cómo construirla en Azure Container Registry y copiarla a Artifact
Registry sin Docker local (sección *2C.6 Imagen y despliegue en Cloud Run*). En los comandos aparece
como `<IMAGEN_DEL_MCP>`, por ejemplo `europe-west1-docker.pkg.dev/<GCP_PROJECT_ID>/<repositorio>/mcp-server:v5`.

**Un servicio por API:** el MCP acepta tokens de **una sola API** (`API_CLIENT_ID`). Si ya tienes otro
servicio con otra API, despliega uno nuevo en lugar de cambiar el existente.

| Variable | Valor | Qué controla | Si está mal |
|---|---|---|---|
| `TENANT_ID` | `<TENANT_ID>` | `iss` y `tid` | 401 |
| `API_CLIENT_ID` | `<API_APP_ID>` (Paso 3) | `aud` | 401 |
| `ALLOWED_CLIENT_IDS` | `<CONNECTOR_APP_ID>` (Paso 4) | `azp` | 403 |
| `RESOURCE_URL` | `https://mcp-piloto-<GCP_PROJECT_NUMBER>.europe-west1.run.app` | URL que anuncia el MCP | El contenedor no arranca si no empieza por `https://` |
| `MCP_RUNTIME` | `gcp-cloud-run-piloto` | Etiqueta `runtime` de la respuesta | Informativa |

El rol `MCP.User` lo exige el MCP por defecto. `PROBE_CLIENT_ID` (job de prueba de Azure) no se usa
aquí.

### 11.1 Variables

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$e = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).entra
$API_APP = $e.apiClientId; $CLI_APP = $e.connectorClientId
$PJ = '<GCP_PROJECT_ID>'; $SVC = 'mcp-piloto'
$HOST_PR = "$SVC-<GCP_PROJECT_NUMBER>.europe-west1.run.app"
```

- La URL es **predecible**: `<servicio>-<número de proyecto>.<región>.run.app`. Hace falta antes de
  desplegar, porque va en `RESOURCE_URL`.
- No uses `$HOST` como nombre de variable: es una variable reservada de PowerShell.

### 11.2 Desplegar

```powershell
gcloud run deploy $SVC --project $PJ --region europe-west1 `
  --image <IMAGEN_DEL_MCP> `
  --ingress internal --no-invoker-iam-check --min-instances 0 --max-instances 1 --memory 512Mi `
  --set-env-vars "TENANT_ID=<TENANT_ID>,API_CLIENT_ID=$API_APP,ALLOWED_CLIENT_IDS=$CLI_APP,RESOURCE_URL=https://$HOST_PR,MCP_RUNTIME=gcp-cloud-run-piloto" `
  --labels 'purpose=mcp-piloto,data=synthetic-only'
```

| Opción | Para qué |
|---|---|
| **`--ingress internal`** | Rechaza el tráfico de Internet. Solo acepta el de la red privada de GCP: VPC, VPN y endpoint PSC |
| **`--no-invoker-iam-check`** | Desactiva la autenticación de Google, porque la valida el MCP con el token de Entra. Sin ella, Google respondería 403 |
| `--min-instances 0` / `--max-instances 1` | Casi sin coste. La primera llamada tarda unos segundos más (arranque en frío) |
| `--set-env-vars` | Variables separadas por comas, entre comillas dobles para que PowerShell sustituya los valores |

**No queda abierto:** `ingress internal` corta Internet, y el MCP rechaza todo lo que no traiga un token
de Entra válido. Son dos controles independientes.

**Consola:** sirve para revisar (**Cloud Run →** `mcp-piloto` **→ Redes, Seguridad y Variables**). Para
crearlo, mejor la CLI: así *ingress* y autenticación quedan explícitos.

### 11.3 a 11.5 Comprobaciones

```powershell
gcloud run services describe $SVC --region europe-west1 --project $PJ --format="yaml(metadata.annotations.'run.googleapis.com/ingress',metadata.annotations.'run.googleapis.com/invoker-iam-disabled',spec.template.spec.containers[0].image,spec.template.spec.containers[0].env)"
gcloud run services describe $SVC --region europe-west1 --project $PJ --format="value(metadata.annotations.'run.googleapis.com/urls')"
$filtro = "resource.type=`"cloud_run_revision`" AND resource.labels.service_name=`"$SVC`" AND jsonPayload.event=`"listening`""
gcloud logging read $filtro --project $PJ --freshness=1h --limit 1 --format="table(timestamp,jsonPayload.event,jsonPayload.port)"
$errores = "resource.type=`"cloud_run_revision`" AND resource.labels.service_name=`"$SVC`" AND severity>=ERROR"
gcloud logging read $errores --project $PJ --freshness=1h --limit 5 --format="table(timestamp,severity,textPayload)"
curl.exe -s -o NUL -w '%{http_code}' "https://$HOST_PR/healthz"
```

- `status.url` devuelve la otra forma de URL (`…-ew.a.run.app`). La predecible está en la anotación
  `run.googleapis.com/urls`.
- `gcloud logging read` solo busca en el último día por defecto: `--freshness` ajusta ese margen.
- Las comillas internas del filtro van escapadas con `` ` ``.
- `404` desde Internet es lo correcto. `200` significaría que el servicio está abierto.

Todavía no se puede probar por la red privada: la primera prueba real es el diagnóstico del Paso 16.

### 11.6 Ficha

```powershell
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
$c.gcp | Add-Member -Force -NotePropertyName cloudRunHost -NotePropertyValue $HOST_PR
$c.gcp | Add-Member -Force -NotePropertyName pscAddress -NotePropertyValue '10.96.0.10'
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
```

### Quién lo hace y qué acordar

- **Para producción**, una **cuenta de servicio dedicada sin roles** (`--service-account`), en lugar de
  la cuenta por defecto de Compute Engine.
- **Si su MCP no es Cloud Run**, lo que se mantiene es la validación del token de Entra (sección 3.1 del
  README) y que solo sea accesible por la red privada.


---

## Paso 12 de 18. VNets delegadas de Power Platform

**Objetivo:** crear las subredes donde Power Platform **inyecta sus contenedores** cuando el conector
llama al MCP. La llamada sale con una IP privada (`10.97.x` o `10.98.x`) y sigue tus rutas y tu DNS. Es
lo que sustituye al On-premises Data Gateway, y por eso OAuth deja de estar bloqueado.

| Decisión | Valor | Por qué |
|---|---|---|
| Dos VNets | `canadacentral` y `canadaeast` | La geografía `canada` tiene dos regiones, y el conector puede ejecutarse en cualquiera. Con una sola fallaría a veces |
| Rangos | `10.97.0.0/24` y `10.98.0.0/24`, subredes `/26` | Libres en la suscripción y sin solapes |
| Tamaño | `/26` en las dos | Deben ser iguales. Entre 6 y 10 IP para entornos que no son de producción y entre 25 y 30 para producción. Cambiar el rango después de delegar requiere un caso de soporte |
| Delegación | `Microsoft.PowerPlatform/enterprisePolicies` | Subred exclusiva de Power Platform |
| DNS | El de Azure (por defecto) | Resuelve las zonas privadas. **No se puede cambiar con la política vinculada** |
| Subred | `pp-delegated` | La política la referencia por nombre |

### 12.1 Crear

**Portal:** **Redes virtuales → + Crear**:
- **Básico:** grupo nuevo `rg-mcp-piloto`, `piloto-pp-canadacentral`, Canada Central.
- **Seguridad:** sin Bastion, Firewall ni DDoS.
- **Direcciones IP:** espacio `10.97.0.0/24`; elimina la subred `default`; añade la subred
  `pp-delegated` (`10.97.0.0`, `/26`) con **Delegación de subred** =
  `Microsoft.PowerPlatform/enterprisePolicies`.

Repite con `piloto-pp-canadaeast` en Canada East, con `10.98.0.0/24` y `10.98.0.0/26`.

**CLI:**

```powershell
$RGP = 'rg-mcp-piloto'
az group create -n $RGP -l canadacentral --tags purpose=mcp-piloto data=synthetic-only -o table
az network vnet create -g $RGP -n piloto-pp-canadacentral -l canadacentral --address-prefixes 10.97.0.0/24 `
  --subnet-name pp-delegated --subnet-prefixes 10.97.0.0/26 --tags purpose=mcp-piloto -o none
az network vnet create -g $RGP -n piloto-pp-canadaeast -l canadaeast --address-prefixes 10.98.0.0/24 `
  --subnet-name pp-delegated --subnet-prefixes 10.98.0.0/26 --tags purpose=mcp-piloto -o none
foreach ($r in 'canadacentral', 'canadaeast') {
  az network vnet subnet update -g $RGP --vnet-name "piloto-pp-$r" -n pp-delegated --delegations Microsoft.PowerPlatform/enterprisePolicies -o none
}
```

La región del grupo de recursos solo indica dónde se guardan sus metadatos; cada recurso tiene su
propia región.

### 12.2 Comprobar

```powershell
$RGP = 'rg-mcp-piloto'
'canadacentral', 'canadaeast' | ForEach-Object {
  $v = az network vnet show -g $RGP -n "piloto-pp-$_" -o json | ConvertFrom-Json
  $s = $v.subnets | Where-Object name -eq 'pp-delegated'
  [pscustomobject]@{
    vnet = $v.name; region = $v.location; espacio = ($v.addressSpace.addressPrefixes -join ',')
    dns = if ($v.dhcpOptions.dnsServers) { $v.dhcpOptions.dnsServers -join ',' } else { 'Azure (por defecto)' }
    subred = $s.name; prefijo = $s.addressPrefix; delegada = $s.delegations[0].serviceName
    nsg = if ($s.networkSecurityGroup) { $s.networkSecurityGroup.id.Split('/')[-1] } else { '(ninguno)' }
  }
} | Format-List
```

- **La salida de un `foreach (...) { }` no se puede canalizar con `|`.** Por eso se usa `ForEach-Object`,
  donde `$_` es cada elemento. `Format-List` evita que la consola corte las columnas.
- **NSG:** puede aparecer uno creado por una directiva de la suscripción. Solo tiene las reglas
  predeterminadas, y `AllowVnetOutBound` permite la salida hacia `VirtualNetwork`, incluidas las redes
  emparejadas y las de la VPN. No lo borres.

### 12.3 Ficha

```powershell
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
$c.powerPlatform | Add-Member -Force -NotePropertyName delegatedSubnetCidrs -NotePropertyValue @('10.97.0.0/26', '10.98.0.0/26')
$c | Add-Member -Force -NotePropertyName azure -NotePropertyValue ([pscustomobject]@{ resourceGroup = 'rg-mcp-piloto' })
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
```

### Quién lo hace y qué acordar

- Las regiones son las de la geografía del entorno: `westeurope` y `northeurope` para *Europe*.
- Rangos libres en todas sus redes y del mismo tamaño. Si varios entornos comparten la política,
  conviene un tamaño mayor.
- **DNS:** si usan un DNS corporativo o un Private Resolver, hay que configurarlo **antes** de vincular
  la política.
- **NSG:** sirve para limitar la salida a TCP 443 hacia los MCP.
- Una subred delegada solo puede estar en **una** Enterprise Policy.


---

## Paso 13 de 18. Peering con el hub (*gateway transit*) y rutas

**Objetivo:** unir tus VNets al hub para que **usen su VPN Gateway**. Si el hub ya da servicio a otras
redes, el cambio es seguro: solo **añade** peerings con **nombres nuevos** (`to-piloto-pp-*`) y no
toca los existentes.

```
piloto-pp-canadacentral (10.97) ─┐ to-hub            to-piloto-pp-canadacentral ┌─ HUB 10.91 ─ VPN Gateway ─► GCP
piloto-pp-canadaeast    (10.98) ─┘ (usa la puerta remota)  (permite el tránsito) ──┘
```

| Mitad | Nombre | Opción | Qué significa |
|---|---|---|---|
| En el hub | `to-piloto-pp-<región>` | **Permitir *gateway transit*** | El hub **ofrece** su gateway |
| En tu VNet | `to-hub` | **Usar la puerta de enlace remota** | Tu VNet **usa** el gateway del hub |

- Después, el VPN Gateway **anuncia por BGP** `10.97.0.0/24` y `10.98.0.0/24` a GCP, y tus VNets aprenden
  las rutas de GCP. **No se toca nada en GCP.**
- **Orden: primero el hub.** La mitad que usa la puerta remota falla si la otra no permite el tránsito.

### 13.1 Crear

**Portal:** **Redes virtuales →** `piloto-pp-canadacentral` **→ Emparejamientos → + Agregar**. El
formulario crea las dos mitades:
- **Bloque remoto (el hub):**
  - nombre `to-piloto-pp-canadacentral`;
  - red `<vnet-hub>`;
  - acceso ✅, tráfico reenviado ☐, **tránsito de la puerta de enlace ✅**, puerta remota ☐.
- **Bloque local (tu VNet):**
  - nombre `to-hub`;
  - acceso ✅, reenviado ☐, tránsito ☐, **usar la puerta de enlace remota ✅**.

Repite desde `piloto-pp-canadaeast`. Los textos de las casillas cambian entre versiones del portal:
guíate por el significado.

**CLI:**

```powershell
$HUB = az network vnet show -g <rg-hub> -n <vnet-hub> --query id -o tsv
foreach ($r in 'canadacentral', 'canadaeast') {
  $SPOKE = az network vnet show -g rg-mcp-piloto -n "piloto-pp-$r" --query id -o tsv
  az network vnet peering create -g <rg-hub> --vnet-name <vnet-hub> -n "to-piloto-pp-$r" `
    --remote-vnet $SPOKE --allow-vnet-access --allow-gateway-transit -o none
  az network vnet peering create -g rg-mcp-piloto --vnet-name "piloto-pp-$r" -n to-hub `
    --remote-vnet $HUB --allow-vnet-access --use-remote-gateways -o none
}
```

- `--remote-vnet` lleva el **ID completo** porque las VNets están en grupos de recursos distintos.
- No se usa `--allow-forwarded-traffic`, porque no hay firewall ni NVA en el hub.
- El peering global (entre regiones distintas) admite *gateway transit* y tiene un pequeño coste por
  GB transferido.

### 13.2 Comprobar los peerings

```powershell
az network vnet peering list -g <rg-hub> --vnet-name <vnet-hub> -o json | ConvertFrom-Json |
  Select-Object @{n='peering';e={$_.name}}, @{n='estado';e={$_.peeringState}}, @{n='transitoGateway';e={$_.allowGatewayTransit}}, @{n='redRemota';e={$_.remoteVirtualNetwork.id.Split('/')[-1]}} | Format-Table -AutoSize
'canadacentral', 'canadaeast' | ForEach-Object {
  $vnet = "piloto-pp-$_"
  az network vnet peering list -g rg-mcp-piloto --vnet-name $vnet -o json | ConvertFrom-Json |
    Select-Object @{n='vnet';e={$vnet}}, @{n='peering';e={$_.name}}, @{n='estado';e={$_.peeringState}}, @{n='usaGatewayRemoto';e={$_.useRemoteGateways}}, @{n='redRemota';e={$_.remoteVirtualNetwork.id.Split('/')[-1]}}
} | Format-Table -AutoSize
```

- Dentro de una propiedad calculada (`@{n=…;e={…}}`), **`$_` es el peering**, no la región. Por eso la
  región se guarda antes en `$vnet`.
- `$using:` solo funciona en ejecuciones remotas o en paralelo: fuera de ellas no da error, pero
  devuelve un valor vacío.
- `Initiated` significa que solo existe una de las dos mitades.

### 13.3 Comprobar que GCP aprende tus redes

Después de 1 o 2 minutos:

```powershell
gcloud compute routers get-status <cloud-router> --region europe-west1 --project <GCP_PROJECT_ID> --flatten="result.bestRoutes[]" --format="table(result.bestRoutes.destRange:label=RED_DE_AZURE,result.bestRoutes.nextHopIp:label=SIGUIENTE_SALTO)"
az network vnet-gateway list-advertised-routes -g <rg-hub> -n <vpn-gateway> --peer 169.254.21.2 --query "value[].network" -o tsv
```

Se anuncia el espacio de la VNet (`/24`), no la subred (`/26`). El firewall del MCP debe
permitir las **subredes `/26`**, que son el origen real de las llamadas.

### Quién lo hace y qué acordar

- Lo hace el **equipo de red** de Azure, porque el peering se crea también en su hub. Si no tienes
  permisos en el hub:
  - crea solo tu mitad, con `pp-network.bicep` y `createReversePeering=false`;
  - pídeles la suya con *Allow gateway transit*.
- **Nombres únicos en el hub:** `pp-network.bicep` nombra la mitad del hub `to-pp-<región>`. Un
  segundo entorno en las mismas regiones chocaría con esos nombres. En ese caso, usa
  `createReversePeering=false` y crea la mitad del hub a mano con otro nombre, como en esta guía.
- **Si el hub tiene firewall o NVA:** *Allow forwarded traffic* y rutas definidas por el usuario. Es
  otro diseño, que hay que revisar con su equipo de red.
- **Primera comprobación si el TCP del Paso 16 falla:** que su router (de GCP u on-premises) aprende
  los rangos de Power Platform.


---

## Paso 14 de 18. DNS privado para el nombre del MCP

**Objetivo:** que, cuando Power Platform pregunte por la URL del MCP desde tus VNets, la respuesta sea
la IP privada del endpoint PSC.

| Quién pregunta | Resultado |
|---|---|
| Internet | DNS público → IP pública → Cloud Run lo rechaza (404) |
| Power Platform desde tus VNets | Zona privada → **`10.96.0.10`** → VPN → PSC → Cloud Run lo acepta |

- El **DNS de Azure** consulta primero las **zonas privadas vinculadas** a la VNet.
- La zona lleva el **nombre exacto** del servicio. Una zona `run.app` rompería todos los demás servicios
  de Cloud Run.
- Se conserva el nombre en la URL, en lugar de la IP, para que el **certificado** de Google coincida.

Recarga de variables:

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$g = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).gcp
$RGP = 'rg-mcp-piloto'; $Z = $g.cloudRunHost; $PSC = $g.pscAddress
```

### 14.1 Crear

**Portal:**
1. **Zonas DNS privadas → + Crear**: grupo `rg-mcp-piloto`, nombre exacto
   `mcp-piloto-<GCP_PROJECT_NUMBER>.europe-west1.run.app`.
2. **Conjuntos de registros → + Agregar**: nombre vacío (`@`), tipo A, `10.96.0.10`.
3. **Vínculos de red virtual → + Agregar**: uno por VNet, **sin registro automático**.

**CLI:**

```powershell
az network private-dns zone create -g $RGP -n $Z -o none
az network private-dns record-set a add-record -g $RGP -z $Z -n '@' -a $PSC -o none
foreach ($r in 'canadacentral', 'canadaeast') {
  $id = az network vnet show -g $RGP -n "piloto-pp-$r" --query id -o tsv
  az network private-dns link vnet create -g $RGP -z $Z -n "piloto-pp-$r" -v $id -e false -o none
}
```

- `@` es la raíz de la zona, es decir, el propio nombre.
- Sin TTL explícito queda en 3600 s; no importa, porque la IP del PSC no cambia.
- `-e false` desactiva el registro automático, que solo sirve para VM.
- No se vincula al hub, porque en este escenario nadie resuelve el nombre desde allí. Vincúlala también si quieres probar desde una VM del hub.
- **Vincular o desvincular zonas se puede hacer con la política vinculada.** Lo que no se puede cambiar
  son los *Servidores DNS* de la VNet.

### 14.2 Comprobar

```powershell
az network private-dns zone show -g $RGP -n $Z --query "{zona:name, registros:numberOfRecordSets, vinculos:numberOfVirtualNetworkLinks}" -o table
az network private-dns record-set a list -g $RGP -z $Z --query "[].{nombre:name, ttl:ttl, ip:join(',', aRecords[].ipv4Address)}" -o table
az network private-dns link vnet list -g $RGP -z $Z -o json | ConvertFrom-Json |
  Select-Object @{n='vinculo';e={$_.name}}, @{n='vnet';e={$_.virtualNetwork.id.Split('/')[-1]}}, @{n='autoRegistro';e={$_.registrationEnabled}}, @{n='estado';e={$_.virtualNetworkLinkState}} | Format-Table -AutoSize
```

Un error tipográfico en el nombre de la zona no produce ningún error: la zona simplemente no se usa.
La resolución real se prueba desde Power Platform en el Paso 16.

### Quién lo hace y qué acordar

| Caso | DNS |
|---|---|
| Cloud Run | Igual: una zona con el nombre exacto de cada servicio → IP del PSC |
| F5 con nombre propio | **A:** zona privada en Azure con un registro A → VIP. **B:** Private Resolver con reenvío a Cloud DNS o al DNS corporativo. Las VNets de Power Platform deben usar el *inbound endpoint* como DNS **antes** de vincular la política |

**Pregunta:** ¿quién es la fuente de verdad de los nombres de sus MCP?


---

## Paso 15 de 18. Enterprise Policy (VNet Support)

**Objetivo:** crear el recurso de **Azure** que reúne las dos subredes delegadas en un objeto que
**Power Platform** entiende. En el Paso 16 se asigna al entorno.

```
Subred 10.97.0.0/26 (Canada Central) ─┐
                                       ├─► Enterprise Policy "piloto-pp-network" ──(Paso 16)──► Entorno "MCP Piloto VNet"
Subred 10.98.0.0/26 (Canada East)   ──┘     tipo NetworkInjection, ubicación canada
```

- **Por qué es un recurso aparte:** la red la gestiona el equipo de Azure y el entorno, el administrador
  de Power Platform. La política es el contrato entre los dos.

| Propiedad | Valor | Para qué |
|---|---|---|
| Tipo | `NetworkInjection` | El tipo de VNet Support. Hay otros tipos de Enterprise Policy, como el de claves de cifrado |
| Ubicación | `canada` | La **geografía de Power Platform** (`geo` del Paso 5), no una región de Azure. Si no coincide, no se puede vincular |
| Redes | Las dos VNets con `pp-delegated` | Una por región. La subred se indica por su nombre |

| Regla | Consecuencia |
|---|---|
| Una política vinculada **no se puede modificar** | Hay que desvincularla para cambiarla. Por eso se crea al final |
| Una subred, una sola política | No se pueden reutilizar subredes que ya estén en otra política |
| Una política puede servir a varios entornos | Por ejemplo, desarrollo y pruebas compartiendo red |
| Quien la vincula debe poder leerla | Rol **Lector** si es otra persona |

### 15.0 Preparación

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$RGP = 'rg-mcp-piloto'; $POL = 'piloto-pp-network'
$LOC = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).powerPlatform.policyLocation
$V1 = az network vnet show -g $RGP -n piloto-pp-canadacentral --query id -o tsv
$V2 = az network vnet show -g $RGP -n piloto-pp-canadaeast --query id -o tsv
```

La plantilla pide el **ID completo** de cada VNet, que puede estar en otro grupo de recursos o en otra
suscripción.

### 15.1 Plantilla oficial

Es la del **paso 7 del procedimiento manual** de la
[guía oficial](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure). El
portal no tiene un formulario propio para este recurso.

| Parte de la plantilla | Qué hace |
|---|---|
| `parameters` | Nombre, geografía, y subred + ID de cada VNet |
| `vNetTwoSupplied` | Las geografías con una sola región (Sweden, Italy) solo necesitan una VNet |
| `resources` | Un recurso `Microsoft.PowerPlatform/enterprisePolicies`, tipo `NetworkInjection` |

### 15.2 Portal

1. **Implementar una plantilla personalizada → Crear su propia plantilla en el editor** → pega la
   plantilla → **Guardar**.
2. Rellena:
   - grupo `rg-mcp-piloto`;
   - *Policy Name* `piloto-pp-network`;
   - *Powerplatform Environment Region* `canada`;
   - en las dos VNets, *Subnet Name* `pp-delegated` y *Resource Id* `$V1` / `$V2`.
3. **Revisar y crear** (espera a *Validación superada*) → **Crear**.

La *Región* del formulario es la del **despliegue** (dónde se guarda su historial), no la de la
política.

### 15.3 CLI (misma plantilla, validada antes)

1. Guarda la plantilla en `$tpl` (con el bloque `@' … '@`; la línea final `'@` va en la primera columna).
2. Valida y crea:

```powershell
az deployment group validate -g $RGP --template-file $tpl `
  --parameters policyName=$POL powerplatformEnvironmentRegion=$LOC vNetOneSubnetName=pp-delegated vNetOneResourceId=$V1 vNetTwoSubnetName=pp-delegated vNetTwoResourceId=$V2 `
  --query "{estado:properties.provisioningState, error:error.message}" -o table
az deployment group create -g $RGP -n enterprise-policy-piloto --template-file $tpl `
  --parameters policyName=$POL powerplatformEnvironmentRegion=$LOC vNetOneSubnetName=pp-delegated vNetOneResourceId=$V1 vNetTwoSubnetName=pp-delegated vNetTwoResourceId=$V2 `
  --query "{despliegue:name, estado:properties.provisioningState}" -o table
```

`validate` comprueba la plantilla, los parámetros y los permisos **sin crear nada**. Con tus VNets
devolvió `Succeeded` antes de crear.

| Error | Causa |
|---|---|
| *Subnet … is not delegated* | Falta la delegación (Paso 12) |
| *Location/region mismatch* | Las VNets no están en la pareja de la geografía |
| *Subnet already associated* | La subred ya está en otra política |
| *ResourceNotFound* | Un ID de VNet mal copiado |

Si se crea con `az rest` en lugar de la plantilla, en la URL hay que escribir `` $POL`? ``: sin el acento
grave, PowerShell toma `$POL?api` como nombre de variable y la URL sale rota.

### 15.4 Comprobar

```powershell
$p = az resource show -g $RGP -n $POL --resource-type Microsoft.PowerPlatform/enterprisePolicies -o json | ConvertFrom-Json
[pscustomobject]@{ nombre = $p.name; ubicacion = $p.location; tipo = $p.kind; systemId = $p.properties.systemId
  vnets = ($p.properties.networkInjection.virtualNetworks | ForEach-Object { $_.id.Split('/')[-1] + '/' + $_.subnet.name }) -join ', ' } | Format-List
```

| Identificador | Formato | Uso |
|---|---|---|
| ID de Azure | `/subscriptions/…/enterprisePolicies/piloto-pp-network` | Permisos y borrado |
| **`systemId`** | `/regions/canada/providers/Microsoft.PowerPlatform/enterprisePolicies/<GUID>` | Vincular y desvincular en Power Platform |

En el portal la política aparece en el grupo de recursos (activa *Mostrar tipos ocultos*).

### 15.5 Ficha

```powershell
$c = Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json
$c.powerPlatform | Add-Member -Force -NotePropertyName policyName -NotePropertyValue $p.name
$c.powerPlatform | Add-Member -Force -NotePropertyName policySystemId -NotePropertyValue $p.properties.systemId
$c.powerPlatform | Add-Member -Force -NotePropertyName policyArmId -NotePropertyValue $p.id
$c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:MCP_LAB_CONFIG -Encoding utf8
```

### Quién lo hace y qué acordar

- La crea el **equipo de Azure** y la vincula el **administrador de Power Platform**. Si son personas
  distintas, este necesita el rol **Lector** sobre la política.
- **Antes de crearla**, revisa por última vez el DNS de las VNets, los rangos, el tamaño de las subredes
  y las regiones.
- Ubicación = `geo` del entorno: **`europe`** para la geografía *Europe*.
- Alternativa: el módulo de PowerShell `Microsoft.PowerPlatform.EnterprisePolicies`
  (`New-SubnetInjectionEnterprisePolicy`).


---

## Paso 16 de 18. Vincular la política al entorno y diagnóstico desde Power Platform

**Objetivo:** que el entorno ejecute sus conectores **en tus subredes**, y demostrar desde dentro de
Power Platform que llega al MCP por la red privada.

```
Agente ─► conector ─► contenedor INYECTADO en 10.97.0.x / 10.98.0.x ─► DNS privado ─► peering ─► VPN ─► PSC ─► Cloud Run
```

| Antes de vincular | Después de vincular |
|---|---|
| Los conectores salen por la infraestructura compartida de Power Platform | Salen **desde tus subredes**, con tu DNS y tus rutas |
| No se llega a un MCP privado | Se llega por la VPN, **sin On-premises Data Gateway** |
| OAuth del conector | **Igual**: va directo a Entra ID y no depende de la red. **Por eso desaparece el conflicto entre OAuth y el gateway** |

Avisos:
- La vinculación puede provocar **hasta 30 minutos de inestabilidad**.
- Después, ni la política ni el DNS de las VNets se pueden cambiar sin desvincular.

### 16.1 Vincular

**Portal (guía oficial):** **Power Platform admin center → Seguridad → Datos y privacidad → Directivas
de Azure Virtual Network** → entorno `MCP Piloto VNet` → política `piloto-pp-network` → **Guardar**.

**CLI** (la misma API que `Enable-SubnetInjection`), con protección frente a valores vacíos:

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
$pp = (Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).powerPlatform
$ENV_ID = $pp.environmentId; $POLICY_SYSTEM_ID = $pp.policySystemId
if (-not $ENV_ID -or -not $POLICY_SYSTEM_ID) { throw 'Falta environmentId o policySystemId en la ficha: revisa los Pasos 5.5 y 15.5' }
"entorno: $ENV_ID"; "política: $POLICY_SYSTEM_ID"
@{ SystemId = $POLICY_SYSTEM_ID } | ConvertTo-Json | Set-Content -LiteralPath "$env:TEMP\link.json" -Encoding ascii
az rest --method POST --resource https://service.powerapps.com/ --headers Content-Type=application/json `
  --url "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$ENV_ID/enterprisePolicies/NetworkInjection/link?api-version=2019-10-01" `
  --body "@$env:TEMP\link.json"
Remove-Item -LiteralPath "$env:TEMP\link.json"
```

**Lección aprendida:** en el primer intento, `$POLICY_SYSTEM_ID` estaba vacía en la consola. Se envió
`"SystemId": null` y la respuesta fue *InvalidEnterprisePolicyRequest: The enterprise policy id from
the route and body do not match*. No se vinculó nada. Por eso el bloque lee la ficha y se detiene si
falta un valor. Ojo también al espacio en `--resource https://…`.

### 16.2 Comprobar la vinculación

```powershell
az rest --method GET --resource https://service.powerapps.com/ `
  --url "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/${ENV_ID}?api-version=2016-11-01" `
  --query "properties.enterprisePolicies.vNets.{estado:linkStatus, ubicacion:location, systemId:systemId}" -o json
```

- Resultado esperado: `Linked`.
- `${ENV_ID}` lleva llaves porque va justo antes de `?`.
- En el portal: **Entornos → Historial → Correcto**.

### 16.3 Diagnóstico desde Power Platform

**Para qué:** es la prueba definitiva de la red. Un contenedor **inyectado en tu subred**, en cada
región, prueba DNS, TCP y TLS hacia el MCP. Es el mismo camino que seguirá el agente.

```powershell
.\tools\pp-vnet-diagnostics.ps1 -HostName $((Get-Content -LiteralPath $env:MCP_LAB_CONFIG -Raw | ConvertFrom-Json).gcp.cloudRunHost) |
  ConvertFrom-Json | ForEach-Object {
  [pscustomobject]@{
    region       = $_.region
    ipContenedor = $_.tcp.containerIpAddress
    dns          = if ($_.dns.status) { "ERROR $($_.dns.status): reintentar" } else { $_.dns.ipAddresses -join ',' }
    tcp          = if ($_.tcp.status) { "ERROR $($_.tcp.status): reintentar" } else { $_.tcp.tcpSuccess }
    tls          = if ($_.tls.status) { "ERROR $($_.tls.status): reintentar" } else { "$($_.tls.sslWithCRL.protocols) · errores: $($_.tls.sslWithCRL.sslErrors)" }
    certificado  = if ($_.tls.certificate) { "$($_.tls.certificate.issuer) · caducado: $($_.tls.certificate.isExpired) · autofirmado: $($_.tls.certificate.isSelfSigned)" }
  }
} | Format-List
```

- El script toma de la ficha **el entorno y las regiones**. Sin `$env:MCP_LAB_CONFIG`, diagnosticaría
  el entorno de otro fichero de configuración.
- `sslErrors` está dentro de `tls.sslWithCRL`, y el certificado en `tls.certificate`.

| Síntoma | Qué hacer |
|---|---|
| `ERROR 503: reintentar` | El contenedor de diagnóstico se está preparando (*Container allocated… Please re-try*). Espera 1 o 2 minutos. Ocurre en los primeros minutos tras vincular y puede afectar a una sola región |
| `ipContenedor` de otra red | Estás diagnosticando otro entorno: revisa `$env:MCP_LAB_CONFIG` |
| `dns` público | Zona privada (Paso 14) |
| `tcp` `False` | Rutas (Paso 13.3) |
| `tls` con errores | Certificado (con un F5, el del **F5**) |

### 16.4 NSG automáticos

```powershell
'canadacentral', 'canadaeast' | ForEach-Object {
  $s = az network vnet subnet show -g rg-mcp-piloto --vnet-name "piloto-pp-$_" -n pp-delegated -o json | ConvertFrom-Json
  "piloto-pp-{0}: {1}" -f $_, $(if ($s.networkSecurityGroup) { $s.networkSecurityGroup.id.Split('/')[-1] } else { '(sin NSG)' })
}
```

- Tras vincular, una directiva de la suscripción puede crear un NSG en cada subred (en la validación,
  `piloto-pp-<región>-pp-delegated-nsg-<región>`).
- Tienen 0 reglas propias y las 6 predeterminadas. `AllowVnetOutBound` permite la salida hacia
  `VirtualNetwork`, incluidas las redes emparejadas y las aprendidas por la VPN. **No bloquean**, y lo
  confirma el TCP del 16.3.
- No se borran; desaparecen con el grupo de recursos.
- Una plantilla que no los declare podría quitarlos al redesplegar. Por eso existe
  `subnetNsgIds` en `pp-network.bicep`.

### Quién lo hace y qué acordar

- Lo hace el **administrador de Power Platform**, en una **ventana de cambios**.
- **El diagnóstico del 16.3 es la herramienta clave de la sesión.** Si DNS, TCP y TLS salen bien en las
  dos regiones, la red está resuelta, y cualquier fallo posterior será de identidad o del agente.
- **Para volver atrás:** `…/NetworkInjection/unlink` o `Disable-SubnetInjection`.


---

## Paso 17 de 18. Agente y herramienta MCP en Copilot Studio

**Objetivo:** unir la **red privada** (Pasos 6 a 16) y la **identidad** (Pasos 2 a 4) en un agente.

| Pieza | Dónde se configura | Por debajo |
|---|---|---|
| Red | **En ningún sitio**: no se elige red ni gateway. El entorno ya está vinculado | VNet Support |
| Identidad | Asistente MCP: OAuth 2.0 con tu cliente y tu API | Entra ID, directo, sin pasar por la VNet |

**El mensaje clave:** con el gateway había que elegir entre «gateway» u «OAuth» en el
conector. Con VNet Support, la red es una propiedad **del entorno** y el conector solo configura
OAuth. **Ya no compiten.**

### 17.1 Agente

1. **Copilot Studio**: selector de **entorno** (arriba a la derecha) → `MCP Piloto VNet`. En otro
   entorno, el conector saldría a Internet y Cloud Run respondería 404.
2. **Crear → Nuevo agente → Omitir para configurar** → nombre `Agente MCP GCP VNet`.
3. **Instrucciones:**

```
Cuando el usuario pida comprobar la conexión con el MCP, usa la herramienta iam_connection_check y responde siempre en español con este formato exacto, sin añadir, quitar ni reordenar secciones:

1. Primera línea: "La conexión con el MCP funciona: el servidor MCP privado está accesible y el token se ha validado."
2. Línea con el texto en negrita: **Resultado completo:**
3. Un bloque de código json con la respuesta de la herramienta tal cual, sin modificar, resumir ni reordenar campos. Nunca uses tablas ni listas para mostrar este resultado.
4. Una lista con exactamente estos cuatro puntos, en este orden:
   - **Origen:** el valor del campo runtime, explicando si el servidor MCP se ejecuta en Azure o en Google Cloud.
   - **Estado:** el token es válido y hay acceso.
   - **Modo:** el valor de identity.mode; si es delegated, indica que se usan permisos delegados en nombre de tu usuario.
   - **Datos sintéticos:** synthetic: true indica que la respuesta usa datos de prueba y no sistemas corporativos reales.

Si la herramienta devuelve un error, no uses este formato: explica el error en una o dos frases e indica el código HTTP si aparece.
```

   Sin instrucciones, el modelo cambia el formato de la respuesta de una vez a otra (JSON, tabla,
   lista).

4. **Configuración → Seguridad → Autenticación** = **Authenticate with Microsoft** (por defecto).
   Identifica a quién habla con el agente (SSO en Teams). El token para el MCP es **otra capa**: lo
   gestiona la conexión de la herramienta.

### 17.2 Secreto

```powershell
Set-Location '<ruta-del-repositorio>'
$env:MCP_LAB_CONFIG = "$env:USERPROFILE\mcp-piloto.config.json"
.\tools\new-connector-secret.ps1
```

El script crea un secreto de 30 días en **tu** cliente (lo lee de la ficha) y lo copia al
portapapeles sin mostrarlo. El conector lo usa para cambiar el código de autorización por el token.

### 17.3 Servidor MCP

**Herramientas → + Agregar una herramienta → + Nueva herramienta → Model Context Protocol:**

| Campo | Valor | Para qué |
|---|---|---|
| Server name | `MCP Piloto` | Nombre del **conector**. Debe coincidir con `connectorDisplayName` de la ficha (lo usa el Paso 18) |
| Server description | `Herramienta de diagnóstico del MCP privado. Úsala cuando el usuario pida comprobar la conexión con el MCP o verificar con qué identidad accede.` | Para que el modelo sepa cuándo usarla |
| Server URL | `https://mcp-piloto-<GCP_PROJECT_NUMBER>.europe-west1.run.app/mcp` | Resuelve a `10.96.0.10` desde tus subredes, y el certificado coincide con el nombre |
| Authentication / Type | OAuth 2.0 / **Manual** | Entra ID no admite el registro dinámico de clientes |
| Client ID | `<CONNECTOR_APP_ID>` | `azp` del token. El MCP solo acepta este cliente |
| Client secret | Ctrl+V | El del 17.2 |
| Authorization URL | `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/authorize` | Inicio de sesión, solo en este tenant |
| Token URL / Refresh URL | `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token` | Obtención y renovación del token |
| Scopes | `api://<API_APP_ID>/MCP.Access offline_access` | `aud` y `scp` de tu API, más el *refresh token* |

Las URL de Entra **no pasan por la VNet**: solo la llamada al MCP va por la red privada.

### 17.4 Callback

Al pulsar **Create**, el asistente muestra la *callback URL*. Ejecuta estas dos líneas **por separado**:

```powershell
.\tools\set-connector-redirect.ps1 -CallbackUrl 'https://global.consent.azure-apim.net/redirect/...'
```
```powershell
Set-Clipboard -Value ' '
```

- Entra solo devuelve el código a URL registradas, y **cada conector tiene la suya**.
- El script **añade** la URL a tu cliente, sin borrar las demás.
- Hay que esperar entre 1 y 2 minutos; si no, aparece `AADSTS50011`.

### 17.5 Conexión y credenciales

1. **Crear una nueva conexión → Iniciar sesión.** Entra comprueba el rol `MCP.User`
   (`AADSTS50105` si falta).
2. **Autenticación = Cuenta de usuario final**: cada usuario usa su propio token. Con las credenciales
   del creador, todos llamarían con la misma identidad, que es lo que hay que evitar.
3. Comprueba que `iam_connection_check` está **activada**: significa que `tools/list` ya ha cruzado
   la red y la validación del token.

**Incidencia vista en la validación:** *«No se pudieron cargar las herramientas de MCP… El servidor MCP
rechazó la solicitud (HTTP 503)»*, unos minutos después de vincular la política.
- Los registros de Cloud Run demostraron que **esa petición no llegó al servicio**: no había ninguna
  antes del primer `200`.
- Fue **inestabilidad temporal de Power Platform** tras vincular la política (la guía oficial avisa
  de hasta 30 minutos), y al reintentar funcionó.
- **Cómo distinguirlo:** si en los registros del MCP no hay petición, el problema está antes de su
  red.

### 17.6 Probar

En **Probar**, escribe `Comprueba la conexión con el MCP`.

| Campo | Valor esperado | Qué demuestra |
|---|---|---|
| `runtime` | `gcp-cloud-run-piloto` | Respondió tu MCP |
| `identity.mode` | `delegated` | El token es de usuario |
| `identity.objectId` | `<ADMIN_OBJECT_ID>` | Tu identidad llega al MCP |
| `identity.clientId` | `<CONNECTOR_APP_ID>` | Lo pidió tu conector |

Auditoría desde el lado del MCP:

```powershell
.\tools\show-gcp-mcp-audit.ps1 -Minutes 30
```

**IP de origen `0.0.0.0`:** en Cloud Run, el tráfico que entra por un endpoint PSC no muestra la IP
del cliente. No se puede filtrar por IP: la protección es el *ingress* `internal` más el token de Entra.

| Síntoma | Qué revisar |
|---|---|
| `AADSTS50011` | Callback (17.4) y esperar |
| `AADSTS50105` | Grupo y rol (Pasos 2 y 3.5) |
| `AADSTS65001` | Consentimiento (4.4) |
| 503 recién vinculado | Esperar y reintentar |
| 401 | Scopes o URL de otro tenant |
| 403 | Cliente distinto o falta el rol |
| 404 o *timeout* | El agente no está en el entorno vinculado, o falla la red (16.3) |


---

## Paso 18 de 18. Publicar en Teams y dar acceso a otro usuario

**Para qué:** llevar el agente a Teams y comprobar que **otro usuario**, que no es el creador, lo
usa con **su propia identidad**. Además, validar que el **grupo de Microsoft 365** sirve para
compartir el agente y para la lectura del conector.

### 18.1 Publicar y añadir el canal de Teams

**Portal:** Copilot Studio → agente → **Publicar**. Después, **Canales → Microsoft 365 y Microsoft
Teams** → **Agregar canal**.

- **Disponibilidad:** *Microsoft 365 Copilot y Microsoft Teams* o *Solo en Microsoft Teams*. **No se
  puede cambiar después.**
- **No uses** *Enviar al catálogo de la organización*.
- Prueba como creador: **Ver en Teams → Agregar → Abrir**. Con SSO no aparece la tarjeta *Conectar*.

### 18.2 Enlace de instalación para los demás

**Portal:** agente → **Compartir** → **Copy sharing link ⌄** → **Copy can use link › Teams**.

| Opción del menú | Qué devuelve | ¿Instala? |
|---|---|---|
| Copy link to set up | `…/channels/pva-studio/user-connections?shareRef=…`: página *Administrar sus conexiones* | ❌ |
| **Copy can use link › Teams** | `https://teams.microsoft.com/l/app/?titleId=T_…` | ✅ |

**Alternativa sin interfaz:** `templateInstanceId` es el campo `componentidunique` del agente en la
tabla `bots` de Dataverse. Con él se construye
`https://teams.microsoft.com/l/app/<TEAMS_APP_ID>?templateInstanceId=<componentidunique>&environment=<environmentId>`.

```powershell
. .\tools\lab-config.ps1
$org = Get-LabSetting powerPlatform.orgUrl
$tok = az account get-access-token --resource $org --query accessToken -o tsv
(Invoke-RestMethod -Uri "$org/api/data/v9.2/bots?`$select=name,componentidunique" `
  -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/json' }).value
```

### 18.3 A. Compartir el agente con el grupo

**Para qué:** que los miembros del grupo puedan instalar y usar el agente.

**Portal:** agente → **Compartir** → busca `MCP-Piloto` (identifícalo por su correo, no elijas las
aplicaciones que también aparecen) → permiso **usar** → **Compartir**. *Org-wide sharing* desactivado.

- *Bot not found* en el primer intento: **temporal**, al reintentar funcionó.
- El permiso de usar **no se guarda como permiso de Dataverse** sobre el agente: por eso no da acceso
  al conector (18.4).
- El mensaje de éxito menciona la activación en **Centro de administración de M365 → Agentes**; no
  hizo falta para que el segundo usuario lo usara.

### 18.4 B. Lectura del conector para el grupo

**Para qué:** sin lectura del conector, el usuario ve *«Connector information unavailable»* al crear
su conexión.

```powershell
.\tools\grant-connector-access.ps1
```

El script detecta que el grupo es de Microsoft 365 y crea el equipo de Dataverse como *grupo de Office
de Microsoft Entra ID* (`teamtype 3`); con un grupo de seguridad usaría `teamtype 2`.

### 18.5 C. Prueba con el segundo usuario

**Portal:** ventana InPrivate → Teams con el segundo usuario → enlace de 18.2 → **Agregar → Abrir** → tarjeta
**Conectar** → **Create new connection** → volver a Teams → `Comprueba la conexión con el MCP`.

```powershell
.\tools\show-gcp-mcp-audit.ps1 -Minutes 30
```

