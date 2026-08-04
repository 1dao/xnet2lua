# xnet2lua

Un pequeño runtime de red en C con una capa de scripting de Lua embebida. El núcleo en C gestiona el polling multiplataforma, el multihilo y los temporizadores; la capa de Lua expone una API de estilo actor donde cada hilo del SO posee un estado de Lua aislado y se comunica a través de POST asíncronos o RPC respaldados por corrutinas.

## Características

- Polling multiplataforma: epoll en Linux, kqueue en macOS/BSD, WSAPoll en Windows, y fallback a `poll`.
- Estado de Lua por hilo con hilos de trabajo gestionados por el framework (`xthread`).
- Mensajes asíncronos (`xthread.post`) y RPC síncrono sobre corrutinas (`xthread.rpc`).
- Lua embebido vía `minilua` por defecto; LuaJIT opcional mediante `LUA_BACKEND=luajit`.
- Bindings de Lua: `xnet` (sockets / TLS / estadísticas del runtime), `xthread` (hilos / RPC / estadísticas de cola), `xtimer` (rueda de temporizadores), `xutils` (JSON vía yyjson, configuración, sistema de archivos), `xcompress` (gzip/deflate/checksums), `cmsgpack` (MessagePack), `xdebug` (adaptador de depuración opcional para VSCode).
- Módulos compartidos de Lua: `xhttp` (servidor HTTP/1.x con router), `xrouter` (despacho unificado de POST/RPC), stacks de trabajadores `xredis` / `xmysql` / `xnats`, `xsession` (ayudante de sesión HTTP).
- Protocolo de recarga en caliente (hot reload), RPC entre procesos sobre NATS, y una consola `xadmin` para ejecución/recarga remota con autenticación empresarial (contraseña, JWT/HS256, OAuth2+PKCE, mTLS) y un modelo de roles de administrador/visor.
- Pruebas de regresión integradas con una matriz de CI que cubre tanto banderas de compilación reducidas como completas.

## Arquitectura

```
+-----------------------------------------------------------+
|  Capa de Aplicación Lua (tus scripts)                     |
+--------------------------------------+--------------------+
|  xnet (sockets / TLS)                | xthread            |
|  xutils (JSON / config)              | (hilos / RPC)      |
|  cmsgpack (MessagePack)              | xtimer             |
+--------------------------------------+--------------------+
|  Núcleo C: xpoll / xchannel / xsock / xtimer / xthread    |
+-----------------------------------------------------------+
|  Terceros: minilua / LuaJIT / mbedTLS / yyjson /          |
|               rpmalloc / libdeflate / lpegrex             |
+-----------------------------------------------------------+
```

Opciones de diseño clave:

- **Un estado de Lua por hilo del SO.** Los hilos están totalmente aislados; nada se comparte por referencia.
- **Dos primitivas de mensajería.** `post` es "dispara y olvida"; `rpc` ejecuta el llamador en una corrutina y lo reanuda con la respuesta.
- **Un backend de polling por plataforma, elegido en tiempo de compilación.** La misma API de Lua independientemente de la interfaz del SO subyacente.

Consulta [`xnet2lua-docs-en.md`](xnet2lua-docs-en.md) (o la versión en chino) para la justificación completa del diseño.

## Estructura del Proyecto

```
xnet2lua/
  Makefile / build.bat       Puntos de entrada GNU make + MSVC
  x{poll,sock,thread,timer,channel,args,daemon,log}.[ch]
                             Núcleo C (bucle de eventos, pool de hilos, sockets, ...)
  xlua/                      Ejecutor de Lua + bindings C->Lua (luaopen_xnet, luaopen_xthread, ...)
  scripts/core/share/        Módulos de Lua puro reutilizables (xrouter, xhttp_router, xsession, ...)
  scripts/core/server/       Hilos de servicio (trabajadores xhttp, xredis, xmysql, xnats)
  demo/                      Scripts de ejemplo ejecutables + regresión de xthread en C
  tests/                     Pruebas unitarias (C + Lua) y el orquestador de pruebas de CI
  tools/                     xdebug_dap — Adaptador DAP para depuración de Lua en VSCode
  3rd/                       Código de terceros incluido o como submódulos
```

## Requisitos

- GCC/Clang con `make` en Linux y macOS.
- MSYS2 MinGW-w64 GCC con `make`, o MSVC a través de `build.bat`, en Windows.
- La compilación predeterminada `LUA_BACKEND=minilua` **no** requiere dependencias externas — `3rd/minilua.h` está incluido en el árbol.

### Componentes opcionales de terceros

Cada uno se activa mediante una bandera de compilación y reside en `3rd/` como submódulo (o librería de archivo único).

| Componente   | Activación                    | Uso                                   | Ruta del submódulo  |
| ----------- | ----------------------------- | ------------------------------------- | ------------------ |
| LuaJIT      | `LUA_BACKEND=luajit`          | Runtime LuaJIT 2.1 en lugar de minilua | `3rd/luajit/`      |
| mbedTLS     | `WITH_HTTPS=1` (activo por def)| TLS para `xnet.attach_tls` / HTTPS     | `3rd/mbedtls3/`    |
| rpmalloc    | `WITH_RPMALLOC=1` (activo por def)| Asignador por hilo vía `xmacro.h`    | `3rd/rpmalloc/` |
| yyjson      | siempre                        | JSON en `xutils.json_*`                | `3rd/yyjson.c`     |
| libdeflate  | siempre                        | `xcompress` y `Content-Encoding: gzip/deflate` en xhttp | `3rd/libdeflate/` |
| lpegrex     | opcional, embebido por el usuario| Librería de parseo PEG                | `3rd/lpegrex/`     |

Obtener todos los submódulos:

```sh
git submodule update --init --recursive
```

## Compilación

Compila la librería estática, el ejecutor `xnet` y el ayudante del adaptador de depuración:

```sh
make all
```

Compilación rápida estilo CI sin TLS y rpmalloc:

```sh
make all BUILD_MODE=debug WITH_HTTPS=0 WITH_RPMALLOC=0
```

En Windows con MSVC:

```bat
build.bat
```

Banderas de compilación útiles:

- `BUILD_MODE=debug|release`
- `WITH_HTTP=0|1`
- `WITH_HTTPS=0|1`
- `WITH_RPMALLOC=0|1`
- `WITH_XDEBUG=0|1`  (compila el depurador de Lua en `bin/xnet`; el runtime es opcional)
- `SANITIZE=none|asan`
- `LUA_BACKEND=minilua|luajit`

Artefactos de compilación:

- `bin/xnet` (`.exe`) — Ejecutor de Lua; `./bin/xnet script.lua [KEY=VAL ...]`
- `libxnet.a` — el núcleo en C, enlázalo para embeber xnet2lua en otro programa
- `tools/xdebug_dap` (`.exe`) — Adaptador DAP que sirve de frontal al depurador de Lua en proceso para VSCode
- `bin/test_core` (`.exe`) — Binario de pruebas unitarias en C (construido por los objetivos de test, no por `all`)
- `bin/xthread_test` (`.exe`) — Binario de regresión de hilos en C (construido por los objetivos de test)

### Modo daemon en Linux

En Linux, `xnet` puede desvincularse al fondo antes de que Lua inicie. Actívalo
desde `xnet.cfg`:

```ini
DAEMON=1
```

o desde la línea de comandos:

```sh
bin/xnet scripts/xadmin/xadmin_main.lua DAEMON=1
bin/xnet scripts/xadmin/xadmin_main.lua -d
bin/xnet scripts/xadmin/xadmin_main.lua --daemon
```

El ejecutor precarga `xnet.cfg` antes de convertirse en daemon para que los ajustes a nivel de proceso surtan efecto temprano. Usa `-c ruta/al/archivo.cfg` o `--config ruta/al/archivo.cfg` para cargar otro archivo de configuración antes de convertirlo en daemon. El modo daemon es exclusivo de Linux; otras plataformas devolverán un error de inicio si se solicita.

## Pruebas

La orquestación de pruebas reside en `tests/Makefile`. El `Makefile` raíz mantiene accesos directos de compatibilidad como `make test` y los delega a `tests/`. También puedes llamar a los objetivos directamente desde el directorio de pruebas — `ROOT` por defecto es `..`, por lo que `cd tests && make <target>` funciona sin argumentos adicionales.

### Jerarquía de objetivos

De más rápido a más exhaustivo:

| Objetivo    | Alcance                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------- |
| `unit-c`    | Solo binario unitario de C (`tests/c/test_core.c`).                                                |
| `unit-lua`  | Solo especificaciones unitarias de Lua (`tests/lua/*_spec.lua`).                                    |
| `unit`      | `unit-c` + `unit-lua`.                                                                             |
| `test`      | `unit` + el `xthread_test` de C + los scripts de regresión `test-lua-core` bajo `demo/`.              |
| `matrix`    | `ci-fast` (debug, sin TLS, sin rpmalloc, `test` completo) **y** `ci-feature` (release, TLS + rpmalloc, solo `unit`), ambos con reconstrucción forzada. |

`matrix` es el objetivo **predeterminado** de `tests/Makefile`, por lo que `cd tests && make` sin argumentos ejecuta la matriz completa de dos niveles. Esto es intencionado: alguien que entra en `tests/` generalmente quiere validar ampliamente, y las dos configuraciones cubren rutas de código que una sola configuración predeterminada no podría — ciclo de vida de rpmalloc, puertas de compilación de TLS, comportamiento de optimización en modo release. Elige un objetivo más estrecho explícitamente cuando quieras un resultado más rápido.

### Invocaciones comunes

```sh
make test                                # el raíz delega a tests/
make -C tests test                       # invocación directa
cd tests && make test                    # lo mismo, desde dentro de tests/
cd tests && make                         # matriz completa (predeterminado)
make unit                                # solo capa unitaria
make run-lua SCRIPT=demo/xutils_main.lua # un solo ejemplo de Lua a través del runtime embebido
```

En Windows:

```bat
build.bat unit
build.bat test
build.bat run-lua script=demo/xutils_main.lua
```

### ASan / diagnósticos de fugas (leaks)

Usa los objetivos de ASan cuando busques errores de memoria nativa:

```sh
make asan
make asan-test
make asan-run-lua SCRIPT=demo/xutils_main.lua
```

Estos objetivos se expanden a `BUILD_MODE=debug SANITIZE=asan WITH_RPMALLOC=0`. En toolchains de Linux/macOS exportan:

```sh
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1
```

En Windows, el predeterminado omite `detect_leaks=1` porque el runtime de ASan de MSVC no soporta informes de fugas al estilo de LeakSanitizer. Aun así, detecta errores de memoria nativa como accesos fuera de límites y use-after-free. Para informes de fugas específicamente, ejecuta el objetivo GNU en Linux/WSL u otro runtime de GCC/Clang que incluya LeakSanitizer.

Las compilaciones de ASan escriben binarios separados como `bin/xnet_asan`, `bin/test_core_asan` y `bin/xthread_test_asan`, para que puedan coexistir con las compilaciones normales de release/debug. También puedes llamar al interruptor directamente:

```sh
make -B test BUILD_MODE=debug SANITIZE=asan
```

En Windows con MSVC:

```bat
build.bat asan
build.bat asan test
build.bat asan run-lua script=demo/xutils_main.lua
```

`SANITIZE=asan` y `build.bat asan` fuerzan ambos `WITH_RPMALLOC=0` para que las asignaciones permanezcan visibles para el runtime del sanitizador.

### Matriz de CI

La matriz de CI ejecuta los mismos dos niveles que el objetivo `matrix` local en Linux, macOS y Windows:

- `debug-nohttps-norpmalloc`: `make test` completo con TLS y rpmalloc desactivados para una retroalimentación de regresión rápida.
- `release-https-rpmalloc`: `make unit` después de compilar con TLS y rpmalloc activados para mantener cubiertas esas rutas de compilación.

El carril de depuración de Ubuntu también ejecuta una prueba de humo `gcov` para la capa unitaria de C.

### Cobertura

Genera datos de cobertura unitaria de C locales:

```sh
make coverage-c
# o: cd tests && make coverage-c
```

Esto emite resúmenes `*.gcov` junto al checkout y datos brutos `gcda/gcno` bajo `coverage/`.

## Inicio rápido: servidor HTTP mínimo

Dos archivos: un hilo principal que arranca el pool de trabajadores, y un script de app que registra rutas. Ambos se ejecutan bajo `bin/xnet`.

**`hello_main.lua`** — hilo principal:

```lua
local xhttp = dofile("scripts/core/server/xhttp.lua")

local function __init()
    assert(xhttp.start({
        host         = "127.0.0.1",
        port         = 8080,
        worker_count = 2,
        worker_name  = "hello",
        app_script   = "hello_app.lua",
    }))
end

local function __uninit() end

return { __init = __init, __uninit = __uninit }
```

**`hello_app.lua`** — se ejecuta dentro de cada hilo trabajador:

```lua
local router = dofile("scripts/core/share/xhttp_router.lua")

router.get("/hello", function(req)
    local name = req.query.name or "world"
    return {
        status  = 200,
        body    = "Hello, " .. name .. "!\n",
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
    }
end)

return { handle = function(req) return router.handle(req) end }
```

Compila y ejecuta:

```sh
make all WITH_HTTPS=0
./bin/xnet hello_main.lua
curl http://127.0.0.1:8080/hello?name=xnet2lua
```

## Inicio rápido: WebSocket

Cualquier ruta de app `xhttp` puede ceder una conexión a WebSocket (RFC 6455). Devuelve una tabla con un campo `websocket` y el trabajador completa el apretón de manos `101`, luego el fd habla frames en lugar de HTTP. `scripts/core/share/xwebsocket.lua` gestiona la clave `Sec-WebSocket-Accept`, el enmascaramiento, la fragmentación y los frames de control (ping $\rightarrow$ auto-pong, apretón de manos de cierre).

```lua
local router = dofile("scripts/core/share/xhttp_router.lua")
local xws    = dofile("scripts/core/share/xwebsocket.lua")

router.get("/ws", function(req)
    if not xws.is_upgrade(req) then
        return { status = 426, body = "WebSocket only\n",
                 headers = { Upgrade = "websocket", Connection = "Upgrade" } }
    end
    return {
        protocol  = "echo",                    -- subprotocolo negociado (opcional)
        websocket = {
            on_open    = function(ws) ws:send_text("welcome") end,
            on_message = function(ws, msg, opcode) ws:send_text("echo:" .. msg) end,
            on_close   = function(ws, reason) end,
        },
    }
end)

return { handle = function(req) return router.handle(req) end }
```

El objeto `ws` expone `send_text` / `send_binary` / `send` / `send_ping` / `send_pong` / `close(code, reason)` / `is_open()`. La capa de codec (`xws.encode` / `xws.decode` / `xws.accept_key`) es utilizable por sí sola para impulsar un cliente o en pruebas.

**`wss://` es gratuito:** inicia el servidor con `https = true` (más `cert_file` / `key_file`) y la misma ruta `/ws` ahora hablará WebSocket dentro del túnel TLS — la actualización viaja sobre cualquier transporte al que el trabajador se haya unido, sin código TLS específico de WebSocket. Pruebas propias:

```sh
./bin/xnet demo/xhttp_ws_main.lua     # WebSocket sobre el servidor de pool de trabajadores
./bin/xnet demo/xhttp_wss_main.lua    # WebSocket seguro sobre TLS (WITH_HTTPS=1)
```

## Inicio rápido: mejora de HTTP $\rightarrow$ HTTPS (force-HTTPS + HSTS)

Un servidor `xhttp` en texto plano puede redirigir cada solicitud a su URL `https://` y emitir HSTS para que los clientes compatibles se mantengan en TLS. Actívalo desde `xhttp.start`:

```lua
xhttp.start({
    host = "0.0.0.0", port = 80,
    worker_name = "edge", app_script = "app.lua",
    force_https   = true,        -- redirección 301 de solicitudes en texto plano a https
    redirect_port = 443,         -- puerto HTTPS objetivo (omite :443 de la URL)
    redirect_status = 301,       -- o 302 / 307 / 308
    hsts = { max_age = 31536000, include_subdomains = true },  -- Strict-Transport-Security
})
```

En el listener HTTPS, pasa la misma opción `hsts` y cada respuesta llevará la cabecera `Strict-Transport-Security`. Las mismas primitivas están expuestas en el codec para uso manual: `codec.https_redirect(req, opts)`, `codec.https_url(req, opts)` y `codec.hsts_value(spec)` — todo cubierto por `tests/lua/websocket_spec.lua`.

> Nota: RFC 2817 `Upgrade: TLS` (mejora de protocolo in-band) no está implementado intencionadamente — ningún navegador lo soporta. El par redirección + HSTS anterior es la forma real de mover un servicio HTTP a HTTPS.

## Inicio rápido: cliente HTTP/HTTPS

`scripts/core/share/xhttp_client.lua` es un cliente asíncrono basado en callbacks que se ejecuta en el mismo bucle de eventos de `xnet` que todo lo demás. El texto plano usa `xnet.connect`; HTTPS usa `xnet.connect_tls` (requiere `WITH_HTTPS=1`). Las respuestas se analizan con `xhttp_codec`, por lo que el Content-Length, transfer-encoding chunked, gzip/deflate y el marco `Connection: close` están gestionados, y las redirecciones 3xx se siguen automáticamente.

```lua
local httpc = dofile('scripts/core/share/xhttp_client.lua')

local function __init()
    assert(xnet.init())

    httpc.get('https://example.com/', function(err, resp)
        if err then return print('error: ' .. err) end
        print(resp.status, #resp.body)        -- 200  528
    end)

    httpc.post('http://127.0.0.1:8080/echo', '{"hi":1}', {
        headers = { ['Content-Type'] = 'application/json' },
    }, function(err, resp)
        if err then return print('error: ' .. err) end
        print(resp.body)
    end)
end

return { __init = __init }
```

`httpc.request(opts, cb)` es la forma completa. `opts` acepta: `url` (o `scheme`/`host`/`port`/`path`), `method`, `headers`, `body`, `timeout_ms`, `max_redirects` (por defecto 5), `verify` (verificación de cert TLS, por defecto `true`, usando el CA incluido en `xlua/xnet_cacert.h`), `ca_file` (sobreescribir ruta de CA), y `decompress` (por defecto `true`). El callback se dispara exactamente una vez como `cb(err)` o `cb(nil, resp)`, donde `resp = { status, version, headers, header_list, body }`.

Ejecuta la prueba propia de extremo a extremo (servidor de loopback + cliente sobre HTTP):

```bash
make run-lua SCRIPT=demo/xhttp_client_main.lua
```

Más puntos de entrada:

- `demo/xhttp_client_main.lua` — autotest de cliente HTTP asíncrono (content-length, echo, redirect, chunked, gzip)
- `demo/xhttp_main.lua` — prueba de humo servidor + cliente HTTP
- `demo/xhttp_compress_main.lua` — prueba de humo de compresión de respuesta HTTP y descompresión de solicitud
- `demo/xhttp_ws_main.lua` — autotest de WebSocket sobre el servidor HTTP de pool de trabajadores
- `demo/xhttp_wss_main.lua` — WebSocket seguro (`wss://`) sobre el pool HTTPS (requiere `WITH_HTTPS=1`)
- `demo/xnet_main.lua`  — TCP puro + RPC de `xsession`
- `demo/xcompress_main.lua` — prueba de humo de `xcompress` gzip/deflate/zlib/checksum
- `demo/xraygui_main.lua` — demo de controles interactivos de RayGUI (requiere `tools/raygui.dll`)
- `demo/xrouter_test.lua` / `demo/xhttp_router_test.lua` — comprobaciones unitarias del router
- `demo/xnats_main.lua` — RPC entre procesos sobre NATS (requiere un servidor NATS)

### Demo de RayGUI

`demo/xraygui_main.lua` muestra los controles exportados de RayGUI en una ventana interactiva: botón, checkbox, slider, barra de progreso, cuadros de texto de una/varias líneas, desplegable, vista de lista, además de las características añadidas en esta ronda:

- **Temas de UI** — 5 preajustes en `tools/styles/` (`dark` / `soft` / `nord` / `candy` / `cyber`); aplícalos vía `require("styles.dark").apply(raygui)`.
- **Iconos integrados** — embebe iconos de raygui en el texto de cualquier control con `#iconID#` (ej. `"#131# Play"`); `set_icon_scale(n)` controla su tamaño.
- **Emoji en color** — integrados en un atlas de texturas (`tools/emoji_atlas.png`) y dibujados mediante `draw_texture_ex`, referenciados por nombre a través de una tabla de índice integrada.
- **Botones de Emoji + texto** — `emoji_button()` superpone un emoji en color sobre un botón.
- **Diálogo de confirmación modal** — `messagebox(...)` (ej. el botón Eliminar).
- **API de Texturas** — `load_texture` / `draw_texture` / `draw_texture_ex`.
- Orden z de desplegable/diálogo correcto vía `lock()` / `unlock()`; el cuadro de texto multilínea ahora recorta y se desplaza al cursor; Retroceso/flechas se repiten automáticamente al mantener presionado.

```sh
bin/xnet demo/xraygui_main.lua
```

Para comprobaciones automatizadas, añade un límite de frames para que la ventana se cierre sola:

```sh
bin/xnet demo/xraygui_main.lua frames=120
```

> **⚠️ Plataforma y versión de Lua**
>
> El archivo `tools/raygui.dll` incluido está construido **solo para Windows x64 y Lua 5.5** — enlaza `lua55.dll` y usa la API C de Lua 5.4/5.5. Por lo tanto, **no** se cargará bajo **LuaJIT** u otras versiones de Lua (ABI incompatible), y **no hay binarios de Linux/macOS** en este repositorio.
>
> Para ejecutar la UI en **otra plataforma (Linux / macOS)** o con una **versión de Lua diferente / LuaJIT**, construye el `raygui.dll` / `raygui.so` correspondiente tú mismo desde el repositorio de código fuente y empaquetado — **https://github.com/1dao/xlua_raygui.git** — y colócalo en `tools/`. Su `Makefile` ya gestiona Windows / Linux / macOS; para un runtime que no sea 5.5, apunta la librería de Lua enlazada (y las cabeceras) a tu objetivo (ej. la librería de importación `lua51` de LuaJIT) antes de compilar.

### Prueba de humo de RayGUI

`tools/raygui_smoke_test.lua` pone a prueba el módulo RayGUI de Lua 5.5 en `tools/raygui.dll`. Ejecútalo a través del runtime de Lua embebido de xnet:

```sh
bin/xnet tools/raygui_smoke_test.lua frames=120
```

También puede ejecutarse bajo un ejecutable de Lua independiente que coincida con la ABI de la DLL:

```sh
lua tools/raygui_smoke_test.lua frames=120
# o: lua.exe tools/raygui_smoke_test.lua frames=120
```
**Repositorio de código fuente y empaquetado**: https://github.com/1dao/xlua_raygui.git

## Módulos de Lua

Registrados en C (cargados automáticamente vía `luaL_requiref` en `xlua/xnet_main.c`; `require()` funciona sin ruta de búsqueda):

| Módulo      | Propósito                                                            | Referencia            |
| ----------- | ------------------------------------------------------------------ | -------------------- |
| `xthread`   | ciclo de vida del hilo, POST / RPC, estadísticas de cola, niveles de log, control opcional del depurador | docs §4              |
| `xnet`      | TCP listen / connect / attach, protocolos de frame, TLS, estadísticas, AEAD   | docs §5–§7           |
| `xtimer`    | bindings de bajo nivel para la rueda de temporizadores hashed                              | docs §3.5            |
| `xutils`    | JSON (yyjson), archivos de configuración, escaneo de directorios                        | docs §10             |
| `xcompress` | compresión gzip / deflate / zlib y checksums                    | docs §10A            |
| `cmsgpack`  | codificación / decodificación de MessagePack                                        | docs §9              |

Lua puro, cargado vía `dofile`:

| Ruta                                              | Propósito                                       | Referencia   |
| ------------------------------------------------- | --------------------------------------------- | ----------- |
| `scripts/core/share/xrouter.lua`                  | despacho unificado de POST + RPC con corrutinas   | docs §3.3   |
| `scripts/core/share/xhttp_router.lua`             | router de ruta/método HTTP con parámetros de ruta      | docs §8.5   |
| `scripts/core/share/xhttp_codec.lua`              | parseo de solicitud/respuesta HTTP + ayudantes de redirección-HTTPS/HSTS | docs §8 |
| `scripts/core/share/xhttp_client.lua`             | cliente HTTP/HTTPS asíncrono (get/post/request)    | docs §8     |
| `scripts/core/share/xwebsocket.lua`               | codec WebSocket RFC 6455 + mejora de servidor     | docs §8     |
| `scripts/core/share/xsession.lua`                 | ayudante de sesión solicitud/respuesta sobre `xnet` puro  | docs §5     |
| `scripts/core/share/xtimerx.lua`                  | temporizadores de aplicación seguros para recarga sobre xtimer | docs §3.5  |
| `scripts/core/server/xhttp.lua` + `xhttp_worker.lua` | arranque de servidor HTTP/HTTPS + pool de trabajadores       | docs §8     |
| `scripts/core/server/xredis*.lua`                 | hilo cliente Redis                            | docs (ejemplos) |
| `scripts/core/server/xmysql*.lua`                 | hilo cliente MySQL                            | docs (ejemplos) |
| `scripts/core/server/xnats*.lua`                  | publicar/suscribir NATS + RPC entre procesos    | docs §18    |

## Solución de Problemas

Dos trampas en las que caerás si te desvías de los archivos de compilación proporcionados. Ambas están documentadas detalladamente en docs §2.7.

- **MinGW: rpmalloc debe compilarse con `-DENABLE_OVERRIDE=0`.** De lo contrario, rpmalloc reemplaza el `calloc` de libc que usa el TLS emulado de MinGW, y el primer acceso a cualquier variable `_Thread_local` recursa a través de `calloc $\rightarrow$ rpcalloc $\rightarrow$ get_thread_heap $\rightarrow$ __emutls_get_address $\rightarrow$ calloc $\rightarrow$ ...` y revienta la pila **antes de que se ejecute `main()`**, sin salida alguna en stdout/stderr. El `Makefile` y `build.bat` del proyecto ya pasan esta bandera; si escribes tus propias reglas de compilación, mantenla.
- **`xmacro.h` debe incluirse después de `yyjson.h`.** `xmacro.h` hace `#define free(p) rpfree(p)` (macro tipo función), y la estructura `yyjson_alc` de yyjson tiene un campo `.free` — sin el orden de inclusión correcto, la macro desvirtúa `alc.free(ctx, doc)` en `alc.rpfree((ctx, doc))` y el programa falla al compilar o corrompe el heap. La misma regla se aplica a cualquier cabecera de terceros con campos miembros `.malloc`/`.free`/`.realloc`.

## Documentación

La documentación de referencia detallada se encuentra en:

- [`xnet2lua-docs-en.md`](xnet2lua-docs-en.md) (Inglés)
- [`xnet2lua-docs-cn.md`](xnet2lua-docs-cn.md) (Chino)

Índice orientado a tareas:

| Cuando quieras...                                  | Lee                                   |
| ---------------------------------------------------- | -------------------------------------- |
| Entender el modelo de hilos + estado de Lua           | docs §1, §3, §4                        |
| Embeber xnet2lua en un programa de C                      | docs §2.6                              |
| Elegir un backend de Lua (minilua vs LuaJIT)               | docs §2.5                              |
| Configurar / desactivar rpmalloc                         | docs §2.7                              |
| Escribir un servidor TCP con framing                      | docs §5, §6 + ejemplo completo §13     |
| Añadir TLS a un listener                                | docs §7                                |
| Construir un servicio de API HTTP/HTTPS                      | docs §8 + ejemplo completo §14         |
| Configurar compresión HTTP o usar `xcompress`        | docs §8.6, §10A                        |
| Programar temporizadores de aplicación seguros para recarga              | docs §3.5                              |
| Hacer RPC entre hilos e inspeccionar la presión de la cola       | docs §4.5, §4.9 + ejemplo completo §15 |
| Inspeccionar estadísticas del runtime de red por hilo        | docs §5.6                              |
| Hacer RPC entre procesos sobre NATS                       | docs §18                               |
| Hacer que un módulo sea seguro para recarga en caliente                        | docs §19                               |
| Depurar Lua desde VSCode                                | docs §20                               |
| Operar la consola xadmin (ejecución / recarga remota)    | docs §17                               |
| Asegurar la consola xadmin (login, JWT, OAuth2, mTLS, roles) | docs §17.9–17.17                 |

## Contribuciones

Consulta [`CONTRIBUTING.md`](CONTRIBUTING.md) para el flujo de desarrollo, el estilo de código y las comprobaciones locales esperadas antes de abrir un PR.

## Licencia

El código del proyecto se distribuye bajo la Licencia BSD de 2 Cláusulas. Consulta [`LICENSE`](LICENSE).

El código de terceros bajo `3rd/` mantiene su propia licencia y copyright originales.
