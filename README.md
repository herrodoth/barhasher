# barhasher
Just a small sh for argon2 hashing. 

1) GUI nativ (implicit)
./argon2_hash_tool.sh

Daca esti pe TTY sau fara DISPLAY/WAYLAND, trece automat pe TUI sau CLI interactiv.
2) Fallback la meniul CLI (TUI/CLI)

Fortat TUI:
./argon2_hash_tool.sh --mode tui

Fortat CLI interactiv:
./argon2_hash_tool.sh --mode cli

Sau sari peste GUI chiar daca exista:
NO_GUI=1 ./argon2_hash_tool.sh

3) Mod non-interactiv prin argumente

Parola din stdin:
echo -n 'S3cr3t' | ./argon2_hash_tool.sh --non-interactive --password-stdin \  --type id -t 4 -m 64 -p 4 -l 32 --clipboard --autoclear 15 --out /tmp/hash.txt

Parola din fisier:
./argon2_hash_tool.sh --non-interactive --password-file /root/pw.txt \  --type argon2id -t 3 -m 128 --save --out /root/hash.txt

Parola din variabila de mediu:
ARGON2_PASSWORD='S3cr3t' ./argon2_hash_tool.sh --non-interactive --password-env ARGON2_PASSWORD \  --salt "$(openssl rand -base64 16)" -t 4 -m 64 -p 4 -l 32


Nota: -m este in MiB si trebuie sa fie putere a lui 2 (ex: 64, 128, 256...). Scriptul transforma corect in exponentul -m (in KiB) cerut de argon2.
