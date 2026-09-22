# ZeuzDNC para iOS

Transferencia de programas G-code a maquinas CNC por RS232 desde un iPhone o
iPad. Es el equivalente iOS del ZeuzDNC de la Raspberry Pi: mismo flujo
(carpeta compartida → editor → ENVIAR), misma logica de perfiles de maquina,
pero nativo en Swift + SwiftUI con Liquid Glass.

---

## ⚠️ Lo primero: la cadena OTG no funciona en iOS

**Un iPhone no puede hablar con un adaptador USB-RS232 generico.** La cadena
`iPhone → OTG → USB-A → USB-RS232 → DB9 → DB25` **no funciona**, y no es un
problema de programacion: iOS no expone ninguna API publica para periféricos
USB genericos. No existe `/dev/ttyUSB0`. Los chips FTDI, CH340, PL2303 y
similares son invisibles para el sistema, conectes el cable que conectes.

Esta app resuelve el problema por los caminos que iOS permite:

| Camino | Como funciona | Cuando usarlo |
|---|---|---|
| **Puente ZeuzDNC** (recomendado) | El iPhone le da la orden por WiFi a una Raspberry Pi que **ya corre ZeuzDNC**; ella saca el G-code con su config | Ya tienes la Pi enviando a la maquina. Cero hardware nuevo, cero setup |
| **Puente en red (ser2net)** | El iPhone saca los bytes por TCP; la Pi es solo un cable | Tienes una Pi pero SIN ZeuzDNC, o un servidor serial (Moxa, USR) |
| **Cable MFi** | Cable certificado Redpark directo del iPhone al DB9 | Sin red disponible, o el iPhone tiene que estar junto a la maquina |

El tramo final **DB9 → DB25 sigue siendo solo cableado**: eso no cambia.

La app tiene una capa de transporte intercambiable, asi que el mismo binario
sirve para los tres y para un simulador sin hardware. Cambiar de uno a otro es
elegir otro puerto en la interfaz.

---

## Requisitos

- Xcode 26 o superior, SDK de iOS 26
- iPhone o iPad con iOS 26
- Zeuz Agent en la PC o Mac donde guardas los programas (recomendado), o una
  carpeta compartida por SMB como alternativa
- Un puente serial **o** un cable Redpark (ver abajo)

---

## Puesta en marcha

### 0. Configurar una Orange Pi nueva sin pantalla

1. Graba la imagen Zeuz DNC 0.3 o posterior e inserta la microSD.
2. Enciende la Pi y espera a que termine el primer arranque y reinicio automático.
3. La app detecta por Bluetooth el equipo `zeuz` y abre el asistente.
4. Introduce el SSID, la contraseña y la configuración serial inicial de la
   máquina (nombre, baudrate, bits, paridad, flujo y fin de línea).
5. Cuando la Orange Pi obtenga IP, la app la registra automáticamente como
   **Puente ZeuzDNC** en el puerto `5000`.
6. En el mismo asistente introduce la dirección y el código de seis dígitos de
   Zeuz Agent para conectar la biblioteca tanto al iPhone como a la Orange Pi.

Bluetooth se utiliza solamente para el alta inicial. Los programas, el control
de la Pi y los envíos posteriores circulan por la red local.

### 1. Abrir el proyecto

```bash
open ZeuzDNC.xcodeproj
```

Xcode resuelve solo la dependencia de [AMSMB2](https://github.com/amosavian/AMSMB2)
(cliente SMB2/3). En **Signing & Capabilities** elige tu equipo de desarrollo
y cambia el bundle id si `com.zeuz.dnc` ya esta tomado.

> **Licencia:** AMSMB2 es LGPL v2.1. Para uso interno en el taller no hay
> problema. Si algun dia publicas en el App Store, tiene que ir enlazada
> dinamicamente (Embed & Sign, que es el default de SPM).

### 2. Conectar con Zeuz Agent (recomendado)

1. Abre Zeuz Agent en la PC o Mac y confirma que ambos equipos están en la
   misma red.
2. En el iPhone entra a **Ajustes → Zeuz Agent**.
3. Escribe la dirección que muestra el Agent, por ejemplo
   `http://192.168.1.10:47820`, y su código temporal de seis dígitos.
4. Pulsa **Emparejar y conectar**.

El token queda protegido en el llavero de iOS. Después del emparejamiento, el
iPhone y la Raspberry pueden abrir y editar la misma biblioteca del Agent sin
crear usuarios SMB.

> En esta primera versión, Zeuz Agent comparte y sincroniza los programas. El
> envío físico por RS232 todavía se inicia desde la Raspberry. El antiguo
> puente HTTP del puerto 5000 sigue documentado abajo sólo para instalaciones
> que continúen usando el servidor Flask anterior.

### 2B. Configurar una carpeta SMB (alternativa)

En la app: **⚙︎ Ajustes → Carpeta compartida**

| Campo | Ejemplo |
|---|---|
| Servidor | `192.168.1.10` |
| Recurso compartido | `cnc-programs` |
| Subcarpeta | (vacio, o `torno/2026`) |
| Usuario / Contrasena | las del share |

La contrasena se guarda en el llavero del iPhone, nunca en texto plano.

Al guardar un programa desde Windows o Mac en esa carpeta, **aparece solo en
el iPhone en unos segundos** — la app sondea la carpeta que estas viendo y
recarga solo si cambio.

### 3. Configurar el puente serial

#### Opcion A — dispositivo ZeuzDNC (recomendada)

Si ya tienes ZeuzDNC conectado a la maquina y enviando programas, **no hace
falta instalar nada ni tocar el puerto**. El iPhone le delega el envio por HTTP
y Zeuz usa su propio cable y el perfil de maquina que ya tiene probado.

En la app: **Ajustes → Puertos → Puerto nuevo → "Dispositivo ZeuzDNC"**. Pon
la IP que muestra la pantalla de Zeuz y el puerto `5000`.

| Campo | Valor |
|---|---|
| IP | la de ZeuzDNC (ej. `192.168.1.50`) |
| Puerto HTTP | `5000` |
| Puerto serial | vacio (con un solo adaptador Zeuz lo elige solo) |

**ZeuzDNC es la fuente autoritativa de los perfiles de maquina.** En **Ajustes
→ Maquinas → Sync with ZeuzDNC** el telefono sustituye su copia por los perfiles
reales y los marca con **ZEUZ**. La app comprueba diferencias periódicamente y
avisa cuando hace falta resincronizar.

Esto importa mas de lo que parece: al enviar, **la config serial la aplica
ZeuzDNC**, no el iPhone. Sin sincronizar puedes estar viendo `9600 8N1` en el
telefono mientras Zeuz manda a `38400 7E1` — y perseguir un "error de
paridad" que en realidad es que estabas leyendo la configuracion equivocada.

Las maquinas marcadas **ZEUZ** se editan en la pantalla de ZeuzDNC. El iPhone
las mantiene de solo lectura para que nunca existan dos configuraciones
contradictorias.

Al picar **ENVIAR**, el iPhone hace, contra la API que ZeuzDNC ya expone:
elige la maquina (`/api/machine/select`) y **da la orden** (`/api/send`) sobre
el archivo que **ya esta en Zeuz**; luego sondea `/api/transfer/status` para la
barra de progreso. **No reescribe el programa** — manda el mismo archivo que el
boton de la pantalla de Zeuz, byte por byte. Por eso el iPhone edita y guarda
por SMB directo sobre la carpeta de Zeuz: asi el archivo ya esta actualizado
cuando llega la orden.

> **Probar sin la maquina:** `python3 Tools/fake_zeuz_pi.py` levanta una Pi
> falsa que reproduce el envio (0→100%, finalizar, cancelar) sin abrir ningun
> puerto serial. Apunta el puerto de la app a la IP de tu Mac y pruebalo antes
> de confiarle el torno.

#### Opcion B — Raspberry Pi con ser2net (si NO usas ZeuzDNC en la Pi)

```bash
sudo apt update && sudo apt install -y ser2net
sudo cp Tools/bridge/ser2net.yaml /etc/ser2net.yaml
sudo systemctl enable --now ser2net
```

Aqui el iPhone saca los bytes el mismo por TCP y la Pi es solo un cable:
`ser2net` soporta RFC 2217, asi que la app le dice el baudrate, paridad y
bits en cada envio segun el perfil de la maquina. Usa el tipo de puerto
**"Puente en red (WiFi)"**. No mezcles esto con ZeuzDNC en la misma Pi: los
dos pelearian por el puerto serial.

**Con un hub de varios adaptadores**, descomenta los puertos extra en
`ser2net.yaml` y **anclalos con nombres estables**:

```bash
sudo cp Tools/bridge/99-cnc-serial.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

> Esto importa mas de lo que parece: sin anclar, `/dev/ttyUSB0` y `ttyUSB1`
> se pueden intercambiar al reiniciar la Pi, y el programa del torno acabaria
> en la fresadora sin ningun aviso. El archivo de reglas explica como sacar
> el numero de serie de cada adaptador.

#### Opcion C — servidor serial comercial

Moxa NPort, USR-TCP232 y similares funcionan directo. Suelen exponer un
puerto TCP por cada puerto fisico (4001, 4002…). Si soportan RFC 2217,
enciendelo en la app; si no, deja apagada esa opcion y configura el baudrate
en el propio equipo.

#### Opcion D — cable MFi (sin red)

Cables certificados **Redpark**: `C4-DB9V` (iPhone USB-C) o `L2-DB9V3`
(Lightning). Es el unico tipo de cable que iOS acepta para RS232.

Tres cosas que hay que saber antes de comprarlo:

1. La cadena de protocolo del cable debe estar en `ZeuzDNC-Info.plist` bajo
   `UISupportedExternalAccessoryProtocols` **y** coincidir con la del puerto
   en la app. Si no coinciden, iOS no abre la sesion.
2. **La API publica de iOS no permite fijar baudrate ni paridad** — eso lo
   hace el SDK de Redpark, que va bajo licencia. Sin ese SDK el cable usa su
   configuracion por defecto. El punto de integracion esta marcado en
   `MFiSerialTransport.applyLineConfiguration(_:)`.
3. Apple **no permite publicar en el App Store** apps hechas con el SDK de
   Redpark. Se instalan con tu cuenta de desarrollador o por Apple Business
   Manager. Para una herramienta interna de taller eso alcanza.

### 4. Dar de alta puertos y maquinas

**Ajustes → Puertos → Puerto nuevo.** Cada puerto lleva el nombre que
quieras (*Torno chico*, *Fresadora del fondo*). Para un hub, usa **Puente con
hub** y los crea todos de golpe.

**Ajustes → Maquinas.** Si usas el puente ZeuzDNC, lo primero es
**Sync with ZeuzDNC**: trae los perfiles reales de tus maquinas y sustituye a
los de fabrica. Quedan marcados con **ZEUZ** y se administran desde ZeuzDNC.

Sin Pi (cable MFi o ser2net) los perfiles se dan de alta a mano; vienen Fanuc
(4800 7E2, XON/XOFF, CR) y Fadal (9600 8N1, XON/XOFF, CRLF) solo como semilla.

> ⚠️ Los valores de fabrica son **tipicos, no verificados para tu maquina** — y
> es muy probable que no se parezcan a los tuyos. Sincroniza con ZeuzDNC, o
> confirmalos contra el manual de cada control antes de produccion.

### 5. Probar sin hardware

Crea un puerto de tipo **Simulador**. Reproduce el envio completo respetando
el tiempo real que tardaria a ese baudrate — sirve para ver la barra de
progreso, la cancelacion y los estados sin tener el puente a la mano.

---

## Como se usa

1. **Programas** — explorador de la carpeta compartida, con subcarpetas,
   breadcrumb y busqueda recursiva por nombre. Tocar un programa lo
   selecciona (sin salir de la lista); los gestos hacen el resto:

   | Gesto | Accion |
   |---|---|
   | Deslizar a la **derecha** | **Enviar** — abre la confirmacion |
   | Deslizar a la **izquierda** | **Editar** — abre el editor |
   | Deslizar a la izquierda y seguir | **Eliminar** (segundo boton, nunca con deslizamiento completo) |

2. **Editor** — editar, guardar, buscar y reemplazar, con **coloreado de
   G-code al estilo CIMCO**: G en azul, M en rojo, ejes en verde, arcos en
   turquesa, avance en naranja, husillo en morado, herramienta en dorado y
   comentarios en gris cursiva. El menu **···** tiene la leyenda completa.
   Los archivos de mas de 2 MB se abren en solo lectura.

3. **Enviar** — barra inferior **siempre visible** con maquina, puerto y
   **ENVIAR**. No se oculta al navegar: que maquina y que puerto estan
   elegidos es informacion que hace falta a la vista todo el tiempo. Cuando
   falta algo, el boton se ve pero queda inaccesible y debajo dice exactamente
   que falta.

Igual que en la Pi, **enviar siempre es manual y con confirmacion**. La app
nunca transmite sola porque aparecio un archivo. El boton solo se habilita
cuando hay programa abierto **sin cambios pendientes**, maquina elegida y
puerto elegido — si falta algo, la barra dice exactamente que.

---

## Arquitectura

```
ZeuzDNC/
  ZeuzDNCApp.swift              AppModel: une las piezas y decide si se puede enviar
  Models/
    Machine.swift               Perfil serial (baudrate, bits, paridad, flujo, terminador)
    SerialEndpoint.swift        Puerto con nombre libre (ZeuzDNC / red / MFi / simulador)
    ProgramEntry.swift          Archivos, carpetas y breadcrumb
    TransferState.swift         Estado y eventos de la transferencia
  Services/
    GCodeSender.swift           Payload, troceado, progreso, cancelacion
    Transport/
      SerialTransport.swift     El protocolo que abstrae "por donde salen los bytes"
      NetworkBridgeTransport.swift  TCP + RFC 2217 + XON/XOFF (ser2net, Moxa)
      MFiSerialTransport.swift  ExternalAccessory (cables Redpark)
      MockTransport.swift       Simulador a velocidad real
      ZeuzBridgeClient.swift    Cliente HTTP de la API Flask de la Pi
      ZeuzBridgeSender.swift    Envio delegado: da la orden y sigue el progreso
      TransportFactory.swift
    SMB/
      SMBClient.swift           Cliente SMB2/3 sobre AMSMB2
      SMBPath.swift             Rutas puras: bloquea el path traversal
      ProgramStore.swift        Navegacion, editor y refresco automatico
      SMBSettings.swift
    Stores/                     Persistencia de maquinas, puertos y llavero
  Views/                        SwiftUI con Liquid Glass
    RootView.swift              Lista + barra de envio anclada abajo
    ProgramBrowserView.swift    Explorador, con los gestos de enviar/editar
    EditorView.swift            Editor, buscar y reemplazar
    Components/
      GCodeHighlighter.swift    Colores y tokenizado del G-code
      GCodeEditor.swift         UITextView con coloreado en vivo + leyenda
Tools/
  verify.sh                     Pruebas del nucleo de envio
  fake_zeuz_pi.py               Raspberry Pi falsa para probar el modo ZeuzDNC
  fake_bridge.py                Puente serial falso (para el modo ser2net)
  bridge/                       Configuracion del puente para la Pi
```

### Decisiones que vale la pena conocer

**El vaciado antes de cerrar.** Cuando `send()` de TCP retorna, los bytes solo
llegaron *al puente*: todavia tienen que salir por la linea serial a 4800 o
9600 baud. Si cerraramos ahi, el puente descarta lo que le queda en el buffer
y la maquina recibe el programa **incompleto**. Por eso `drain()` calcula
cuanto tarda fisicamente esa cantidad de bytes a ese baudrate y espera la
diferencia. Es el mismo problema que en la Pi resolvia `out_waiting`.

**El terminador se aplica solo al enviar.** Convertir a CR o CRLF pasa sobre
el contenido en memoria; **el archivo en la carpeta compartida no se toca**.
Un programa que llega de Windows con CRLF y se manda a un Fanuc en CR no
duplica el retorno de carro.

**latin-1 en todo el camino.** Mapea 1 a 1 cada byte, asi que nunca falla al
leer G-code/ISO ni altera el contenido.

**Control de flujo.** Con XON/XOFF la app escucha la linea de vuelta y frena
antes de cada bloque. En goteo no hay limite de tiempo (la maquina puede
tardar minutos en un movimiento largo); en modo punch hay una red de
seguridad de 120 s.

**Las rutas nunca se salen del share.** `SMBPath.sanitize` descarta `..` y
normaliza las barras de Windows, igual que `resolve_path` en la Pi.

---

## Verificacion

```bash
./Tools/verify.sh
```

Levanta un puente serial falso y ejerce el nucleo real de envio:

- la conversion de terminador (CR / CRLF / LF), incluido el caso de un
  archivo que ya venia de Windows con CRLF
- el calculo de bits por byte y tiempo de linea (Fanuc 7E2 = 11 bits)
- **un envio real por TCP, comprobando byte a byte lo que llega al otro lado**
- que un XOFF de la maquina **frene de verdad** el envio, y que las 400 lineas
  lleguen intactas tras el XON
- que un puente apagado de un error entendible en vez de colgarse
- que `..` no pueda salirse de la carpeta compartida

---

## Diferencias con la version de la Raspberry Pi

| | Raspberry Pi | iOS |
|---|---|---|
| Salida serial | `pyserial` sobre `/dev/ttyUSB0` | Puente en red o cable MFi |
| Deteccion de puertos | Automatica por udev | Alta manual, con nombre libre |
| Cambios en la carpeta | `watchdog` (instantaneo) | Sondeo cada 4 s |
| Acceso a los programas | Disco local montado por Samba | Cliente SMB2/3 nativo |
| Perfiles de maquina | `config/machines.json` | En la app, con importador del JSON de la Pi |

Los perfiles de la Pi se pueden importar tal cual: `MachineStore.importFromPi(json:)`
lee el mismo `config/machines.json` sin tocarlo.

---

## Problemas frecuentes

**"No se pudo conectar" al puente.** Comprueba que ser2net corre
(`systemctl status ser2net`) y que el iPhone esta en la misma red. La primera
vez iOS pide permiso de red local: si lo negaste, actívalo en Ajustes de iOS →
ZeuzDNC → Red local.

**El puente rechazo la configuracion (RFC 2217).** El equipo no lo soporta.
Apaga esa opcion en el puerto y configura el baudrate directamente en el puente.

**La maquina recibe basura.** Casi siempre es que el baudrate o la paridad no
coinciden con el control. Verifica el perfil contra el manual. Si es correcto,
prueba invirtiendo DTR/RTS: muchas configuraciones de PC que funcionan los
tienen apagados.

**La maquina no recibe nada.** Ponla en modo recepcion *antes* de tocar
ENVIAR. Revisa tambien que el cable DB9→DB25 tenga el cruce correcto de
TX/RX para tu control.

**El cable MFi no aparece.** Solo funcionan cables certificados. Verifica que
la cadena de protocolo del puerto coincida con la de `ZeuzDNC-Info.plist`.
En **Puertos** se listan los cables que iOS detecta ahora mismo, con sus
protocolos reales — es la forma rapida de saber cual poner.
# Zeuz Agent (migración actual)

La app ya incluye el cliente del protocolo HTTP v1 de Zeuz Agent. En
**Ajustes → Zeuz Agent** se captura la dirección del agente y el código de
seis dígitos; el token resultante se guarda en el llavero de iOS.

`ProgramStore` usa ahora una fuente intercambiable. Zeuz Agent es la opción
preferida y SMB se conserva como compatibilidad durante la transición. La
interfaz, el editor y el flujo de envío no dependen de cuál fuente entregó el
programa.

El servicio Bonjour permitido por la app es `_zeuz-agent._tcp`. La selección
automática de un agente descubierto se agregará en el siguiente incremento;
por ahora puede escribirse su IP o nombre `.local`.

---

### Conexión al taller y edición de perfiles

Ajustes presenta una sola conexión ZEUZ mediante dirección y código. Ya no muestra
SMB, sus credenciales ni opciones de puertos para el flujo del taller. Una instalación
que sólo tenía SMB abre la configuración de ZEUZ; no se borran sus preferencias,
credenciales, perfiles ni archivos. Los transportes existentes siguen en el código.

La lista de máquinas incluye **Editar** y abre el formulario serial existente. Guarda
primero en el equipo conectado; conserva el borrador si hay un error o conflicto de
revisión. La lista se actualiza periódicamente. Los cambios de la pantalla táctil y
Agent llegan por el mismo contrato de perfiles.

Cuando Agent confirma el servidor Pi, iZeuz guarda su dirección y utiliza el mismo
acceso emparejado para continuar si la computadora se desconecta. Conserva ese destino
para nuevas operaciones. Una escritura/envío con respuesta perdida no se repite:
iZeuz pide revisar su estado antes de repetir. El servidor del taller atiende los
programas y enruta las máquinas a sus Pi sin depender de Agent.

Validación del cliente con transporte simulado y los archivos Swift de producción:

```sh
bash Tools/verify_workshop.sh
```

Cubre descubrimiento del servidor de respaldo, cambio de conexión, persistencia del
destino, revisiones de perfiles y ausencia de reenvío de órdenes inciertas.
