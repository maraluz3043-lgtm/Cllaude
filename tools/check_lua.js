// Verificador de sintaxis para los archivos .lua del proyecto (usa luaparse en modo 5.3).
// Restricción del proyecto: Luau compatible con sintaxis Lua 5.1/5.3 (sin `continue`, sin `+=`, sin anotaciones de tipo).
const fs = require('fs'); const path = require('path'); const luaparse = require('luaparse');
const root = process.argv[2]; let files = [];
function walk(d) { for (const e of fs.readdirSync(d, {withFileTypes: true})) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (p.endsWith('.lua') || p.endsWith('.luau')) files.push(p); } }
const st = fs.statSync(root); if (st.isDirectory()) walk(root); else files.push(root);
let bad = 0;
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  try { luaparse.parse(src, {luaVersion: '5.3', comments: false, scope: false}); }
  catch (e) { bad++; console.log('ERROR ' + f + ': ' + e.message); }
}
console.log((files.length - bad) + '/' + files.length + ' archivos con sintaxis válida');
process.exit(bad ? 1 : 0);
