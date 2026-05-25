{ pkgs ? import <nixpkgs> {} }:

let
  luaWithSocket = pkgs.lua5_2.withPackages (ps: [ ps.luasocket ]);
in
pkgs.mkShell {
  buildInputs = [
    luaWithSocket
    pkgs.steam-run
  ];

  shellHook = ''
    export LUA_PATH="${luaWithSocket}/share/lua/5.2/?.lua;${luaWithSocket}/share/lua/5.2/?/init.lua;;"
    export LUA_CPATH="${luaWithSocket}/lib/lua/5.2/?.so;;"

    echo "✅ Lua with luasocket ready."
    echo "🚀 To start the bot:"
    echo "   steam-run ./gbots pipe -name nars_bot -exec 'lua bot_nars.lua'"
    echo ""
    echo "💡 Before that, start UDPNAR in another terminal:"
    echo "   ./NAR UDPNAR 127.0.0.1 50000 10000000 true"
  '';
}
