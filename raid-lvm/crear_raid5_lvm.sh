#!/bin/bash
# crear_raid_lvm.sh
# Script para crear RAID5 -> LVM -> formatear -> montar -> persistencia fstab/mdadm
# ADVERTENCIA: destruirá datos en los discos indicados.

set -euo pipefail

#########################
# CONFIGURACIÓN (edita)
#########################
# Dispositivos que usarán el RAID (separados por espacios)
DEVICES=(/dev/sdb /dev/sdc /dev/sdd)

# Dispositivo md a crear
RAID_DEVICE=/dev/md0

# Nivel RAID y número de dispositivos (auto)
RAID_LEVEL=5

# Punto de montaje temporal para el md (antes de crear LVM)
TEMP_MD_MOUNT=/mnt/raid-md

# Grupo/volumen lógico
VG_NAME=vg-raid5
LV_NAME=lv-datos
LV_MOUNT=/mnt/raid   # Punto final donde quieres montar el LV

# Fichero mdadm.conf (Ubuntu/Debian)
MDADM_CONF=/etc/mdadm/mdadm.conf

# Ejecutar realmente el script? 0 = solo muestra lo que haría, 1 = ejecuta.
EXECUTE=0

# Fin configuración
#########################

log() { echo -e "\n[INFO] $*"; }
err() { echo -e "\n[ERROR] $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  err "Tienes que ejecutar el script como root (sudo)."
fi

if [[ ${#DEVICES[@]} -lt 3 ]]; then
  err "RAID5 necesita al menos 3 dispositivos. Revisa la variable DEVICES."
fi

NUM_DEVICES=${#DEVICES[@]}

echo "=============================================="
echo "AVISO: Este script borrará TODO en: ${DEVICES[*]}"
echo "RAID device: $RAID_DEVICE"
echo "VG: $VG_NAME  LV: $LV_NAME  Mount: $LV_MOUNT"
echo "EXECUTE = $EXECUTE"
echo "=============================================="

if [[ "$EXECUTE" -ne 1 ]]; then
  log "Modo simulación. Cambia EXECUTE=1 en la cabecera del script para ejecutar realmente."
fi

# helper: ejecutar o mostrar
run() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    log "Ejecutando: $*"
    eval "$@"
  else
    log "[DRY RUN] $*"
  fi
}

# 1) Instalar mdadm y lvm2
install_packages() {
  run "apt update -y"
  run "DEBIAN_FRONTEND=noninteractive apt install -y mdadm lvm2"
}

# 2) Comprobar dispositivos
check_devices() {
  for d in "${DEVICES[@]}"; do
    if [[ ! -b "$d" ]]; then
      err "El dispositivo $d no existe o no es un bloque. Revisa DEVICES."
    fi
  done
}

# 3) Crear RAID5
create_raid() {
  # Ensures previous md device does not exist
  if [[ -e "$RAID_DEVICE" ]]; then
    log "$RAID_DEVICE ya existe. Intentaremos desmontarlo/borrar metadata si procede."
    run "mdadm --stop $RAID_DEVICE || true"
    run "mdadm --remove $RAID_DEVICE || true"
  fi

  # Construir lista de dispositivos para el comando
  local devs="${DEVICES[*]}"
  run "mdadm --create --verbose $RAID_DEVICE --level=$RAID_LEVEL --raid-devices=$NUM_DEVICES ${DEVICES[*]}"
  # Esperar un poco y mostrar estado
  log "Estado inicial de /proc/mdstat:"
  run "cat /proc/mdstat"
}

# 4) Formatear md con ext4 y montar temporalmente
format_and_mount_md() {
  run "mkfs.ext4 -F $RAID_DEVICE"
  run "mkdir -p $TEMP_MD_MOUNT"
  run "mount $RAID_DEVICE $TEMP_MD_MOUNT"
  run "sync"
}

# 5) Configurar arranque automático mdadm
configure_md_autostart() {
  # Añadir escaneo al mdadm.conf (evitar duplicados)
  run "mdadm --detail --scan | tee -a $MDADM_CONF >/dev/null"
  run "update-initramfs -u"
  log "mdadm.conf actualizado y initramfs regenerado."
}

# 6) Preparar LVM (desmontar md antes de pvcreate)
create_lvm() {
  # Verificar si está montado y desmontar
  if mount | grep -q "^$RAID_DEVICE"; then
    run "umount $RAID_DEVICE"
  fi
  # Forzar creación PV (el dispositivo puede tener un superblock anterior)
  run "pvcreate -ff -y $RAID_DEVICE"
  run "vgcreate $VG_NAME $RAID_DEVICE"
  run "lvcreate -l 100%FREE -n $LV_NAME $VG_NAME"
  log "LVM creado: /dev/$VG_NAME/$LV_NAME"
}

# 7) Formatear LV y montarlo en LV_MOUNT
format_and_mount_lv() {
  local LV_PATH="/dev/$VG_NAME/$LV_NAME"
  run "mkfs.ext4 -F $LV_PATH"
  run "mkdir -p $LV_MOUNT"
  run "mount $LV_PATH $LV_MOUNT"
  run "sync"
  log "LV montado en $LV_MOUNT"
}

# 8) Actualizar /etc/fstab con UUID del LV (y del md si quieres)
update_fstab() {
  local LV_PATH="/dev/$VG_NAME/$LV_NAME"
  local UUID_LV
  UUID_LV=$(blkid -s UUID -o value "$LV_PATH") || UUID_LV=""
  if [[ -z "$UUID_LV" ]]; then
    err "No se pudo obtener UUID de $LV_PATH"
  fi

  # Añadir entrada para LV en fstab si no existe
  if ! grep -q "$UUID_LV" /etc/fstab 2>/dev/null; then
    local ENTRY="UUID=${UUID_LV} ${LV_MOUNT} ext4 defaults 0 2"
    run "bash -c 'echo \"$ENTRY\" >> /etc/fstab'"
    log "Entrada añadida a /etc/fstab: $ENTRY"
  else
    log "La entrada ya existe en /etc/fstab"
  fi

  # También actualizamos mdadm.conf ya hecho antes; opcional: añadir md UUID a fstab (normalmente no necesario)
}

# 9) Mostrar estado final
final_status() {
  log "Estado /proc/mdstat"
  run "cat /proc/mdstat || true"
  log "LVM display"
  run "vgdisplay $VG_NAME || true"
  run "lvdisplay /dev/$VG_NAME/$LV_NAME || true"
  log "df -h $LV_MOUNT"
  run "df -h $LV_MOUNT || true"
}

# Ejecución ordenada
main() {
  check_devices
  install_packages
  create_raid
  # Dar tiempo a que el RAID comience a sincronizarse (si EXECUTE=1 se mostrará /proc/mdstat)
  log "Mostrando /proc/mdstat (si está en ejecución):"
  run "cat /proc/mdstat || true"
  format_and_mount_md
  configure_md_autostart
  create_lvm
  format_and_mount_lv
  update_fstab
  final_status
  log "FIN. Si EXECUTE=0, cambia EXECUTE=1 para ejecutar realmente."
}

main "$@"