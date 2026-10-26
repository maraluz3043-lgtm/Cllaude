// Ejecuta un archivo Lua 5.3 con fengari y expone utilidades del sistema de archivos al código Lua.
// Uso: node run.js <archivo.lua> [args...]
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const fs = require('fs');
const path = require('path');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function registrar(nombre, fn) {
  lua.lua_pushjsfunction(L, fn);
  lua.lua_setglobal(L, to_luastring(nombre));
}
registrar('leerArchivo', (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  try { lua.lua_pushstring(L, to_luastring(fs.readFileSync(p, 'utf8'))); return 1; }
  catch (e) { lua.lua_pushnil(L); lua.lua_pushstring(L, to_luastring(String(e))); return 2; }
});
registrar('existeArchivo', (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  lua.lua_pushboolean(L, fs.existsSync(p)); return 1;
});
registrar('listarDirectorio', (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  lua.lua_newtable(L);
  let i = 1;
  try {
    for (const e of fs.readdirSync(p, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      lua.lua_newtable(L);
      lua.lua_pushstring(L, to_luastring(e.name)); lua.lua_setfield(L, -2, to_luastring('nombre'));
      lua.lua_pushboolean(L, e.isDirectory()); lua.lua_setfield(L, -2, to_luastring('esDirectorio'));
      lua.lua_rawseti(L, -2, i++);
    }
  } catch (e) { /* directorio inexistente: tabla vacía */ }
  return 1;
});
registrar('relojReal', (L) => { lua.lua_pushnumber(L, Date.now() / 1000); return 1; });
registrar('escribirArchivo', (L) => {
  const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
  const s = to_jsstring(lauxlib.luaL_checkstring(L, 2));
  fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s, 'utf8'); return 0;
});
let codigoSalida = 0;
registrar('salir', (L) => { codigoSalida = lauxlib.luaL_optinteger(L, 1, 0); return 0; });

const archivo = process.argv[2];
if (!archivo) { console.error('uso: node run.js <archivo.lua>'); process.exit(2); }
// RAIZ_SIM: carpeta del simulador; RAIZ_REPO: raíz del repositorio (dos niveles arriba)
const raizSim = __dirname;
lua.lua_pushstring(L, to_luastring(raizSim)); lua.lua_setglobal(L, to_luastring('RAIZ_SIM'));
lua.lua_pushstring(L, to_luastring(path.resolve(raizSim, '..', '..'))); lua.lua_setglobal(L, to_luastring('RAIZ_REPO'));
lua.lua_newtable(L);
process.argv.slice(3).forEach((a, i) => { lua.lua_pushstring(L, to_luastring(a)); lua.lua_rawseti(L, -2, i + 1); });
lua.lua_setglobal(L, to_luastring('ARGS'));

const fuente = fs.readFileSync(archivo, 'utf8');
// package.path para require de la carpeta lib
lua.lua_getglobal(L, to_luastring('package'));
lua.lua_pushstring(L, to_luastring(path.join(raizSim, 'lib', '?.lua') + ';' + path.join(raizSim, '?.lua')));
lua.lua_setfield(L, -2, to_luastring('path'));
lua.lua_pop(L, 1);
lua.lua_getglobal(L, to_luastring('debug'));
lua.lua_getfield(L, -1, to_luastring('traceback'));
const idxTraza = lua.lua_gettop(L);
if (lauxlib.luaL_loadbuffer(L, to_luastring(fuente), null, to_luastring('@' + archivo)) !== lua.LUA_OK) {
  console.error('ERROR DE CARGA:', to_jsstring(lua.lua_tostring(L, -1))); process.exit(1);
}
if (lua.lua_pcall(L, 0, 0, idxTraza) !== lua.LUA_OK) {
  console.error('ERROR DE EJECUCIÓN:', to_jsstring(lua.lua_tostring(L, -1))); process.exit(1);
}
process.exit(codigoSalida);
