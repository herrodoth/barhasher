#!/usr/bin/env bash
# Argon2 Hash Tool: GUI (yad) -> TUI (dialog/whiptail) -> CLI interactiv -> CLI non-interactiv
# Dependinte:
#  - Core: argon2, openssl
#  - GUI: yad
#  - TUI: dialog (preferat) sau whiptail
#  - Clipboard: wl-copy (Wayland) sau xclip (X11)

set -o pipefail

die() {
  echo "Eroare: $*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Clipboard preferinte
CLIP_CMD=""
if [ -n "${WAYLAND_DISPLAY:-}" ] && have wl-copy; then
  CLIP_CMD="wl-copy"
elif have xclip; then
  CLIP_CMD="xclip"
fi

# --------- Default-uri ---------
TYPE="argon2id"    # argon2id/argon2i/argon2d
T=4                # iteratii
MEM_MIB=64         # memorie in MiB (ideal putere a lui 2)
P=4                # paralelism
LEN=32             # lungime hash in bytes
GEN_SALT="TRUE"
SALT_INPUT=""
SAVE_TO_FILE="FALSE"
OUT_PATH="$HOME/hash_output.txt"
COPY_TO_CLIPBOARD="FALSE"
AUTOCLEAR=0
MODE="auto"        # auto | gui | tui | cli | nonint

[ -n "$CLIP_CMD" ] && COPY_TO_CLIPBOARD="TRUE"

# --------- Utilitare ---------
write_secure_file() {
  local path="$1" content="$2"
  umask 177
  printf "%s\n" "$content" > "$path" || return 1
  chmod 600 "$path" 2>/dev/null || true
}

gen_salt() {
  openssl rand -base64 16
}

# calculeaza exponentul -m (in KiB) din MEM_MIB (accepta puteri ale lui 2)
calc_mexp_from_mib() {
  local mib="$1"
  # validare numeric
  [[ "$mib" =~ ^[0-9]+$ ]] || { echo ""; return; }
  local kib=$((mib * 1024))
  local orig="$kib"
  local exp=0
  if [ "$kib" -lt 1 ]; then echo ""; return; fi
  while [ $kib -gt 1 ]; do
    if [ $((kib % 2)) -ne 0 ]; then echo ""; return; fi
    kib=$((kib/2))
    exp=$((exp+1))
  done
  # verifica 2^exp == orig
  if [ $((1<<exp)) -ne "$orig" ]; then echo ""; else echo "$exp"; fi
}

do_hash() {
  local pw="$1"
  local type_flag
  case "$TYPE" in
    argon2id|id) type_flag="-id"; TYPE="argon2id" ;;
    argon2i|i)   type_flag="-i";  TYPE="argon2i"  ;;
    argon2d|d)   type_flag="-d";  TYPE="argon2d"  ;;
    *) die "Tip Argon2 necunoscut: $TYPE (foloseste argon2id/argon2i/argon2d)" ;;
  esac

  local mexp
  mexp=$(calc_mexp_from_mib "$MEM_MIB")
  if [ -z "$mexp" ]; then
    die "Memorie invalida: $MEM_MIB MiB. Foloseste o valoare putere a lui 2 (ex: 64, 128, 256...)."
  fi

  local salt_val
  if [ "$GEN_SALT" = "TRUE" ] || [ -z "$SALT_INPUT" ]; then
    salt_val=$(gen_salt) || die "Nu am putut genera salt random."
  else
    salt_val="$SALT_INPUT"
  fi

  printf %s "$pw" | argon2 "$salt_val" "$type_flag" -t "$T" -m "$mexp" -p "$P" -l "$LEN" -e
}

copy_with_autoclear() {
  local text="$1" seconds="$2"
  if [ "$COPY_TO_CLIPBOARD" = "TRUE" ]; then
    if [ "$CLIP_CMD" = "wl-copy" ]; then
      printf "%s" "$text" | wl-copy || echo "Atentie: wl-copy a esuat." >&2
      if [ "$seconds" -gt 0 ] 2>/dev/null; then ( sleep "$seconds"; wl-copy -c ) >/dev/null 2>&1 & fi
    elif [ "$CLIP_CMD" = "xclip" ]; then
      printf "%s" "$text" | xclip -selection clipboard || echo "Atentie: xclip a esuat." >&2
      if [ "$seconds" -gt 0 ] 2>/dev/null; then ( sleep "$seconds"; printf "" | xclip -selection clipboard ) >/dev/null 2>&1 & fi
    else
      echo "Info: nici wl-copy, nici xclip nu sunt disponibile. Sar peste clipboard."
    fi
  fi
}

# --------- Detectare moduri ---------
can_gui() { [ -z "${NO_GUI:-}" ] && have yad && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; }
can_dialog() { have dialog; }
can_whiptail() { have whiptail; }

# --------- GUI (YAD) ---------
run_gui() {
  for tool in argon2 openssl yad; do have "$tool" || die "❌ $tool nu este instalat. Instaleaza: sudo apt install $tool"; done

  local copy_default="FALSE"; [ -n "$CLIP_CMD" ] && copy_default="TRUE"
  local result status
  result=$(
    yad --form \
      --title="Argon2 Hash Generator" \
      --image=dialog-password \
      --center --borders=12 \
      --text="Introdu parola si selecteaza optiunile (argon2id recomandat pentru parole):" \
      --field="Parola:":H '' \
      --field="Confirma parola:":H '' \
      --field="Tip Argon2:CB" "argon2id!argon2i!argon2d" \
      --field="Iteratii (t):NUM" "$T!1..10!1" \
      --field="Memorie (MiB):CB" "4!8!16!32!64!128!256!512!1024!2048!4096" \
      --field="Paralelism (p):NUM" "$P!1..16!1" \
      --field="Lungime hash (octeti):NUM" "$LEN!16..64!1" \
      --field="Salt (base64, optional):" "$SALT_INPUT" \
      --field="Genereaza salt random:CHK" "$GEN_SALT" \
      --field="Salveaza in fisier:CHK" "$SAVE_TO_FILE" \
      --field="Fisier iesire:FL" "$OUT_PATH" \
      --field="Copiaza in clipboard:CHK" "$copy_default" \
      --field="Auto-clear clipboard (sec):NUM" "$AUTOCLEAR!0..600!5" \
      --button="Genereaza!gtk-ok:0" --button="Anuleaza!gtk-cancel:1" \
      --width=560 --height=420
  ); status=$?
  [ $status -ne 0 ] && exit 0
  local pw pw2 copy_to_clip
  IFS="|" read -r pw pw2 TYPE T MEM_MIB P LEN SALT_INPUT GEN_SALT SAVE_TO_FILE OUT_PATH copy_to_clip AUTOCLEAR <<< "$result"
  [ -z "$pw" ] && die "Parola nu poate fi goala."
  [ "$pw" != "$pw2" ] && die "Parolele nu coincid."
  COPY_TO_CLIPBOARD="$copy_to_clip"

  local hash
  hash=$(do_hash "$pw") || die "Eroare la generarea hash-ului."
  unset pw pw2

  if [ "$SAVE_TO_FILE" = "TRUE" ]; then
    write_secure_file "$OUT_PATH" "$hash" || die "Nu am putut scrie in fisier: $OUT_PATH"
  fi

  copy_with_autoclear "$hash" "$AUTOCLEAR"

  if [ "$SAVE_TO_FILE" = "TRUE" ]; then
    yad --text-info --title="Hash generat (din fisier)" --filename="$OUT_PATH" --width=700 --height=250 --center --borders=10
  else
    printf "%s\n" "$hash" | yad --text-info --title="Hash generat" --width=700 --height=250 --center --borders=10
  fi
}

# --------- TUI (dialog) ---------
run_tui_dialog() {
  for tool in argon2 openssl dialog; do have "$tool" || die "❌ $tool nu este instalat. Instaleaza: sudo apt install $tool"; done
  local pw pw2 resp

  resp=$(dialog --insecure --passwordbox "Parola:" 10 60 3>&1 1>&2 2>&3) || exit 0; pw="$resp"
  resp=$(dialog --insecure --passwordbox "Confirma parola:" 10 60 3>&1 1>&2 2>&3) || exit 0; pw2="$resp"
  [ -z "$pw" ] && die "Parola nu poate fi goala."
  [ "$pw" != "$pw2" ] && die "Parolele nu coincid."

  resp=$(dialog --menu "Tip Argon2" 12 60 3 "argon2id" "Recomandat" "argon2i" "Side-channel" "argon2d" "GPU" 3>&1 1>&2 2>&3) || exit 0; TYPE="$resp"
  resp=$(dialog --inputbox "Iteratii (t) [implicit $T]:" 10 60 "$T" 3>&1 1>&2 2>&3) || exit 0; T="$resp"
  resp=$(dialog --menu "Memorie (MiB)" 14 60 11 4 "" 8 "" 16 "" 32 "" 64 "" 128 "" 256 "" 512 "" 1024 "" 2048 "" 4096 "" 3>&1 1>&2 2>&3) || exit 0; MEM_MIB="$resp"
  resp=$(dialog --inputbox "Paralelism (p) [implicit $P]:" 10 60 "$P" 3>&1 1>&2 2>&3) || exit 0; P="$resp"
  resp=$(dialog --inputbox "Lungime hash (octeti) [implicit $LEN]:" 10 60 "$LEN" 3>&1 1>&2 2>&3) || exit 0; LEN="$resp"

  if dialog --yesno "Genereaza salt random?" 8 60; then GEN_SALT="TRUE"; SALT_INPUT=""; else GEN_SALT="FALSE"; SALT_INPUT=$(dialog --inputbox "Salt (base64):" 10 60 3>&1 1>&2 2>&3) || exit 0; fi
  if dialog --yesno "Salveaza in fisier?" 8 60; then
    SAVE_TO_FILE="TRUE"
    OUT_PATH=$(dialog --fselect "$OUT_PATH" 15 70 3>&1 1>&2 2>&3) || exit 0
    [ -z "$OUT_PATH" ] && die "Cale fisier lipsa."
  else SAVE_TO_FILE="FALSE"; fi

  if dialog --yesno "Copiaza in clipboard?" 8 60; then COPY_TO_CLIPBOARD="TRUE"; AUTOCLEAR=$(dialog --inputbox "Auto-clear (sec) [0=off]:" 10 60 "$AUTOCLEAR" 3>&1 1>&2 2>&3) || exit 0; else COPY_TO_CLIPBOARD="FALSE"; fi

  local hash
  hash=$(do_hash "$pw") || die "Eroare la generarea hash-ului."
  unset pw pw2
  if [ "$SAVE_TO_FILE" = "TRUE" ]; then write_secure_file "$OUT_PATH" "$hash" || die "Nu am putut scrie in fisier: $OUT_PATH"; fi
  copy_with_autoclear "$hash" "$AUTOCLEAR"

  if [ "$SAVE_TO_FILE" = "TRUE" ]; then dialog --title "Hash generat (din fisier)" --textbox "$OUT_PATH" 12 80; else dialog --title "Hash generat" --msgbox "$hash" 12 80; fi
}

# --------- TUI (whiptail) ---------
run_tui_whiptail() {
  for tool in argon2 openssl whiptail; do have "$tool" || die "❌ $tool nu este instalat. Instaleaza: sudo apt install $tool"; done
  local pw pw2
  pw=$(whiptail --passwordbox "Parola:" 10 60 3>&1 1>&2 2>&3) || exit 0
  pw2=$(whiptail --passwordbox "Confirma parola:" 10 60 3>&1 1>&2 2>&3) || exit 0
  [ -z "$pw" ] && die "Parola nu poate fi goala."
  [ "$pw" != "$pw2" ] && die "Parolele nu coincid."

  TYPE=$(whiptail --nocancel --notags --menu "Tip Argon2" 12 60 3 "argon2id" "Recomandat" "argon2i" "Side-channel" "argon2d" "GPU" 3>&1 1>&2 2>&3)
  T=$(whiptail --inputbox "Iteratii (t) [implicit $T]:" 10 60 "$T" 3>&1 1>&2 2>&3) || exit 0
  MEM_MIB=$(whiptail --nocancel --menu "Memorie (MiB)" 14 60 11 4 "" 8 "" 16 "" 32 "" 64 "" 128 "" 256 "" 512 "" 1024 "" 2048 "" 4096 "" 3>&1 1>&2 2>&3)
  P=$(whiptail --inputbox "Paralelism (p) [implicit $P]:" 10 60 "$P" 3>&1 1>&2 2>&3) || exit 0
  LEN=$(whiptail --inputbox "Lungime hash (octeti) [implicit $LEN]:" 10 60 "$LEN" 3>&1 1>&2 2>&3) || exit 0

  if whiptail --yesno "Genereaza salt random?" 8 60; then GEN_SALT="TRUE"; SALT_INPUT=""; else GEN_SALT="FALSE"; SALT_INPUT=$(whiptail --inputbox "Salt (base64):" 10 60 3>&1 1>&2 2>&3) || exit 0; fi
  if whiptail --yesno "Salveaza in fisier?" 8 60; then SAVE_TO_FILE="TRUE"; OUT_PATH=$(whiptail --inputbox "Cale fisier:" 10 60 "$OUT_PATH" 3>&1 1>&2 2>&3) || exit 0; [ -z "$OUT_PATH" ] && die "Cale fisier lipsa."; else SAVE_TO_FILE="FALSE"; fi
  if whiptail --yesno "Copiaza in clipboard?" 8 60; then COPY_TO_CLIPBOARD="TRUE"; AUTOCLEAR=$(whiptail --inputbox "Auto-clear (sec) [0=off]:" 10 60 "$AUTOCLEAR" 3>&1 1>&2 2>&3) || exit 0; else COPY_TO_CLIPBOARD="FALSE"; fi

  local hash
  hash=$(do_hash "$pw") || die "Eroare la generarea hash-ului."
  unset pw pw2
  if [ "$SAVE_TO_FILE" = "TRUE" ]; then write_secure_file "$OUT_PATH" "$hash" || die "Nu am putut scrie in fisier: $OUT_PATH"; fi
  copy_with_autoclear "$hash" "$AUTOCLEAR"

  if [ "$SAVE_TO_FILE" = "TRUE" ]; then whiptail --title "Hash generat (din fisier)" --textbox "$OUT_PATH" 12 80; else whiptail --msgbox "$hash" 12 80; fi
}

# --------- CLI interactiv (prompturi) ---------
run_cli_interactive() {
  for tool in argon2 openssl; do have "$tool" || die "❌ $tool nu este instalat. Instaleaza: sudo apt install $tool"; done
  local pw pw2 resp
  read -r -s -p "Parola: " pw; echo
  read -r -s -p "Confirma parola: " pw2; echo
  [ -z "$pw" ] && die "Parola nu poate fi goala."
  [ "$pw" != "$pw2" ] && die "Parolele nu coincid."

  echo -n "Tip Argon2 [argon2id/argon2i/argon2d] (implicit: $TYPE): "; read -r resp; [ -n "$resp" ] && TYPE="$resp"
  echo -n "Iteratii (t) (implicit: $T): "; read -r resp; [[ "$resp" =~ ^[0-9]+$ ]] && T="$resp"
  echo "Memorie (MiB) (puteri ale lui 2) (implicit: $MEM_MIB): "; read -r resp; [[ "$resp" =~ ^[0-9]+$ ]] && MEM_MIB="$resp"
  echo -n "Paralelism (p) (implicit: $P): "; read -r resp; [[ "$resp" =~ ^[0-9]+$ ]] && P="$resp"
  echo -n "Lungime hash (octeti) (implicit: $LEN): "; read -r resp; [[ "$resp" =~ ^[0-9]+$ ]] && LEN="$resp"

  echo -n "Genereaza salt random? [Y/n] (implicit: Y): "; read -r resp
  if [[ "$resp" =~ ^([nN]|no|No)$ ]]; then GEN_SALT="FALSE"; echo -n "Salt (base64): "; read -r SALT_INPUT; else GEN_SALT="TRUE"; SALT_INPUT=""; fi

  echo -n "Salveaza in fisier? [y/N] (implicit: N): "; read -r resp
  if [[ "$resp" =~ ^([yY]|yes|Yes)$ ]]; then SAVE_TO_FILE="TRUE"; echo -n "Cale fisier (implicit: $OUT_PATH): "; read -r resp; [ -n "$resp" ] && OUT_PATH="$resp"; else SAVE_TO_FILE="FALSE"; fi

  local def_clip=$( [ "$COPY_TO_CLIPBOARD" = "TRUE" ] && echo "Y" || echo "N" )
  echo -n "Copiaza in clipboard? [Y/n] (implicit: $def_clip): "; read -r resp
  if [[ "$resp" =~ ^([nN]|no|No)$ ]]; then COPY_TO_CLIPBOARD="FALSE"; fi
  if [ "$COPY_TO_CLIPBOARD" = "TRUE" ]; then echo -n "Auto-clear clipboard (sec) [0 = off] (implicit: $AUTOCLEAR): "; read -r resp; [[ "$resp" =~ ^[0-9]+$ ]] && AUTOCLEAR="$resp"; fi

  local hash
  hash=$(do_hash "$pw") || die "Eroare la generarea hash-ului."
  unset pw pw2
  if [ "$SAVE_TO_FILE" = "TRUE" ]; then write_secure_file "$OUT_PATH" "$hash" || die "Nu am putut scrie in fisier: $OUT_PATH"; echo "Hash salvat in: $OUT_PATH"; fi
  copy_with_autoclear "$hash" "$AUTOCLEAR"

  echo "Hash:"
  echo "$hash"
}

# --------- CLI non-interactiv (argumente) ---------
PASSWORD_STDIN="FALSE"
PASSWORD_FILE=""
PASSWORD_ENV=""  # ex: ARGON2_PASSWORD

print_help() {
cat <<'EOF'
argon2_hash_tool.sh - generator Argon2 cu GUI/TUI/CLI, plus mod non-interactiv prin argumente

Utilizare:
  Auto (GUI->TUI->CLI interactiv):
    ./argon2_hash_tool.sh

  Fortare mod:
    ./argon2_hash_tool.sh --mode gui
    ./argon2_hash_tool.sh --mode tui
    ./argon2_hash_tool.sh --mode cli
    ./argon2_hash_tool.sh --non-interactive [OPTIUNI] --password-stdin

Optiuni non-interactive:
  --non-interactive           Ruleaza fara prompturi (necesita parola prin stdin/fisier/env)
  --type {argon2id|argon2i|argon2d|id|i|d}
  -t NUM                      Iteratii (t)
  -m NUM_MiB                  Memorie in MiB (trebuie sa fie putere a lui 2)
  -p NUM                      Paralelism
  -l NUM                      Lungime hash (bytes)
  --salt BASE64               Salt in base64 (daca lipseste, se genereaza random)
  --out PATH                  Salveaza in fisierul PATH (permisiuni 600)
  --save                      Forteaza salvarea in fisier (folosind --out sau implicit $HOME/hash_output.txt)
  --clipboard                 Copiaza in clipboard (daca exista wl-copy/xclip)
  --no-clipboard              Dezactiveaza copierea in clipboard
  --autoclear SEC             Curata clipboard dupa SEC secunde (0 = off)

Surse parola (non-interactiv, alege una):
  --password-stdin            Citeste parola din STDIN (ex: echo -n 'pwd' | ./script --non-interactive --password-stdin ...)
  --password-file PATH        Citeste parola din fisier (se citeste tot continutul; newline final este ignorat)
  --password-env [VAR]        Citeste parola din variabila de mediu (implicit: ARGON2_PASSWORD sau numele furnizat)

Altele:
  --mode {auto|gui|tui|cli|nonint}
  --no-gui                    Sare peste GUI chiar daca exista
  -h, --help                  Ajutor

Exemple:
  echo -n 'S3cr3t' | ./argon2_hash_tool.sh --non-interactive --password-stdin --type id -t 4 -m 64 -p 4 -l 32 --clipboard --autoclear 15
  ./argon2_hash_tool.sh --non-interactive --password-file /root/pw.txt --type argon2id -t 3 -m 128 --out /root/hash.txt --save
  ARGON2_PASSWORD='S3cr3t' ./argon2_hash_tool.sh --non-interactive --password-env ARGON2_PASSWORD --salt "$(openssl rand -base64 16)"
EOF
}

run_noninteractive() {
  for tool in argon2 openssl; do have "$tool" || die "❌ $tool nu este instalat. Instaleaza: sudo apt install $tool"; done

  local pw=""
  if [ "$PASSWORD_STDIN" = "TRUE" ]; then
    # citeste tot stdin (nu mascheaza vizual input-ul, by design pentru pipe)
    pw=$(cat)
  elif [ -n "$PASSWORD_FILE" ]; then
    [ -r "$PASSWORD_FILE" ] || die "Nu pot citi fisierul parolei: $PASSWORD_FILE"
    pw=$(cat -- "$PASSWORD_FILE")
  elif [ -n "$PASSWORD_ENV" ]; then
    pw="${!PASSWORD_ENV}"
  elif [ -n "${ARGON2_PASSWORD:-}" ]; then
    pw="$ARGON2_PASSWORD"
  else
    die "In modul non-interactiv trebuie sa furnizezi parola prin --password-stdin, --password-file sau --password-env (sau env ARGON2_PASSWORD)."
  fi

  # elimina un newline final (daca exista)
  pw="${pw%$'\n'}"
  [ -z "$pw" ] && die "Parola nu poate fi goala."

  # daca --save fara --out -> foloseste implicit OUT_PATH
  if [ "$SAVE_TO_FILE" = "TRUE" ] && [ -z "$OUT_PATH" ]; then
    OUT_PATH="$HOME/hash_output.txt"
  fi

  local hash
  hash=$(do_hash "$pw") || die "Eroare la generarea hash-ului."
  unset pw

  if [ "$SAVE_TO_FILE" = "TRUE" ] || [ -n "$OUT_PATH" ]; then
    write_secure_file "$OUT_PATH" "$hash" || die "Nu am putut scrie in fisier: $OUT_PATH"
  fi

  copy_with_autoclear "$hash" "$AUTOCLEAR"

  echo "$hash"
}

# --------- Parsare argumente ---------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --non-interactive) MODE="nonint"; shift ;;
    --no-gui) NO_GUI=1; shift ;;
    --type) TYPE="$2"; shift 2 ;;
    -t) T="$2"; shift 2 ;;
    -m) MEM_MIB="$2"; shift 2 ;;
    -p) P="$2"; shift 2 ;;
    -l) LEN="$2"; shift 2 ;;
    --salt) SALT_INPUT="$2"; GEN_SALT="FALSE"; shift 2 ;;
    --out) OUT_PATH="$2"; SAVE_TO_FILE="TRUE"; shift 2 ;;
    --save) SAVE_TO_FILE="TRUE"; shift ;;
    --clipboard) COPY_TO_CLIPBOARD="TRUE"; shift ;;
    --no-clipboard) COPY_TO_CLIPBOARD="FALSE"; shift ;;
    --autoclear) AUTOCLEAR="$2"; shift 2 ;;
    --password-stdin) PASSWORD_STDIN="TRUE"; shift ;;
    --password-file) PASSWORD_FILE="$2"; shift 2 ;;
    --password-env) PASSWORD_ENV="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Argument necunoscut: $1" >&2; print_help; exit 1 ;;
  esac
done

# --------- Entry ---------
case "$MODE" in
  nonint|non-interactive) run_noninteractive ;;
  gui) can_gui || die "GUI indisponibil. Foloseste --mode tui/cli sau --non-interactive."; run_gui ;;
  tui) if can_dialog; then run_tui_dialog; elif can_whiptail; then run_tui_whiptail; else die "dialog/whiptail indisponibile."; fi ;;
  cli) run_cli_interactive ;;
  auto|*)
    if can_gui; then
      run_gui
    elif can_dialog; then
      run_tui_dialog
    elif can_whiptail; then
      run_tui_whiptail
    else
      run_cli_interactive
    fi
    ;;
esac
