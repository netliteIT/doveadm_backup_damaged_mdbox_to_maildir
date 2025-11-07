#!/bin/bash

# Check if first argument is missing
if [ -z "$1" ]; then
  echo "Error: missing dovecot user."
  echo "Usage: $0 <value>"
  exit 1
fi

USER=$1
BACKUP_ROOT="mailbackup/${USER}"
DOVECOT_KEYWORDS_FILE="/etc/dovecot/dovecot-keywords"  # Modifica se necessario

echo "Backup Maildir: $USER"
echo "Dest: $BACKUP_ROOT"

mkdir -p "$BACKUP_ROOT"

get_maildir_flags() {
    local flags="$1"
    local flag_suffix=""

    [[ "$flags" == *"\\Seen"* ]] && flag_suffix="${flag_suffix}S"
    [[ "$flags" == *"\\Answered"* ]] && flag_suffix="${flag_suffix}R"
    [[ "$flags" == *"\\Flagged"* ]] && flag_suffix="${flag_suffix}F"
    [[ "$flags" == *"\\Deleted"* ]] && flag_suffix="${flag_suffix}T"
    [[ "$flags" == *"\\Draft"* ]] && flag_suffix="${flag_suffix}D"

    if [ -n "$flag_suffix" ]; then
        echo "$flag_suffix"
    else
        echo ""
    fi
}

get_maildir_directory() {
    local flags="$1"
    if [[ "$flags" == *"\\Seen"* ]]; then
        echo "cur"
    else
        echo "new"
    fi
}

generate_maildir_filename() {
    local msg_uid="$1"
    local flags="$2"
    local date_sent="$4"

    local timestamp
    if [ -n "$date_sent" ]; then
        # Prova diversi formati di data
        timestamp=$(date -d "$date_sent" +%s 2>/dev/null)
        if [ $? -ne 0 ]; then
            # Fallback: usa data corrente se conversione fallisce
            echo "Warning: Impossibile convertire data '$date_sent', uso timestamp corrente" >&2
            timestamp=$(date +%s)
        fi
    else
        # Se non c'è data, usa timestamp corrente
        timestamp=$(date +%s)
    fi

    # Componenti del nome file
    local hostname=$(hostname)
    local flags_suffix=$(get_maildir_flags "$flags")

    echo "${timestamp}.${msg_uid}_0.${hostname}:2,${flags_suffix}"
}

convert_email_date() {
    local date_string="$1"
    if [ -z "$date_string" ]; then
        return 1
    fi

    local converted_date

    converted_date=$(date -d "$date_string" "+%Y%m%d%H%M.%S" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$converted_date"
        return 0
    fi

    converted_date=$(date -d "$(echo "$date_string" | sed 's/ +[0-9]*$//')" "+%Y%m%d%H%M.%S" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$converted_date"
        return 0
    fi

    converted_date=$(date -d "$date_string" "+%Y%m%d%H%M" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$converted_date"
        return 0
    fi

    return 1
}


doveadm mailbox list -u "$USER" | while read MAILBOX; do
    echo "Processing mailbox: $MAILBOX"

    if [ "$MAILBOX" = "INBOX" ]; then
        MAILDIR_PATH="$BACKUP_ROOT/"
    else
        MAILDIR_PATH="$BACKUP_ROOT/$(echo "$MAILBOX" | sed 's/\./\//g' | sed 's/^/./')"
    fi

    mkdir -p "$MAILDIR_PATH"/{cur,new,tmp}

    COUNT=0

    mapfile -t uids < <(doveadm search -u "$USER" mailbox "$MAILBOX" ALL | awk '{print $NF}')

    echo "Found ${#uids[@]} messaggesi in $MAILBOX"

    for MSG_UID in "${uids[@]}"; do

        FLAGS=$(doveadm fetch -u "$USER" "flags" mailbox "$MAILBOX" uid "$MSG_UID" 2>/dev/null | awk -F': ' '{print $2}' | sed 's/^ *//')
        SIZE=$(doveadm fetch -u "$USER" "size.physical" mailbox "$MAILBOX" uid "$MSG_UID" 2>/dev/null | awk '{print $NF}')
        DATE_SENT=$(doveadm fetch -u "$USER" "date.sent" mailbox "$MAILBOX" uid "$MSG_UID"  | awk -F': ' '{print $2}' 2>/dev/null)
        DATE_RECEIVED=$(doveadm fetch -u "$USER" "date.received" mailbox "$MAILBOX" uid "$MSG_UID" | awk -F': ' '{print $2}' 2>/dev/null)

        DIR_TYPE=$(get_maildir_directory "$FLAGS")

        FILENAME=$(generate_maildir_filename "$MSG_UID" "$FLAGS" "$DATE_SENT")
        FILE_PATH="$MAILDIR_PATH/$DIR_TYPE/$FILENAME"

        if doveadm fetch -u "$USER" "text" mailbox "$MAILBOX" uid "$MSG_UID" 2>/dev/null | sed '1d' > "$FILE_PATH"; then

            if [ -n "$DATE_SENT" ]; then
                touch_date=$(convert_email_date "$DATE_SENT")
                if [ $? -eq 0 ]; then
                    touch -t "$touch_date" "$FILE_PATH"
                fi
            else
                touch_date=$(convert_email_date "$DATE_RECEIVED")
                if [ $? -eq 0 ]; then
                    touch -t "$touch_date" "$FILE_PATH"
                fi
            fi

            COUNT=$((COUNT + 1))
            echo "  Creato: $MSG_UID - $FILE_PATH - $DATE_SENT - $DATE_RECEIVED -> $touch_date"
        else
            echo "  ERROR: UID $MSG_UID in mailbox $MAILBOX" >&2
        fi
    done

    echo "  Count: $COUNT messagges in $MAILBOX"

    if [ -f "$DOVECOT_KEYWORDS_FILE" ]; then
        cp "$DOVECOT_KEYWORDS_FILE" "$MAILDIR_PATH/dovecot-keywords"
    fi

done
