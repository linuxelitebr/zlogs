#!/bin/bash

# Redirecionando a saída padrão e erros para o syslog
exec 1> >(logger -p user.info -t zram-clean) 2> >(logger -p user.err -t zram-clean)

# Define log directory (this will be replaced durante a instalação)
LOG_DIR="/var/log/debug-zram"

# Definir threshold de utilização (80%)
THRESHOLD=80

# Obter informações do dispositivo zram
get_zram_device() {
    # Encontrar o dispositivo zram montado no diretório de logs
    local mounted_device=$(mount | grep "$LOG_DIR" | awk '{print $1}')
    
    if [[ -z "$mounted_device" ]]; then
        logger -p user.err -t zram-clean "[!] Error: No zram device found mounted at $LOG_DIR"
        return 1
    fi
    
    echo "$mounted_device"
    return 0
}

# Calcular utilização atual em porcentagem
get_zram_usage_percent() {
    local zram_device="$1"
    local zram_name=$(basename "$zram_device")
    local sys_path="/sys/block/$zram_name"
    
    # Verificar se o dispositivo existe
    if [[ ! -e "$sys_path" ]]; then
        logger -p user.err -t zram-clean "[!] Error: Device $zram_device does not exist"
        return 1
    fi
    
    # Obter tamanho total configurado
    local total_size=0
    if [[ -f "$sys_path/disksize" ]]; then
        total_size=$(cat "$sys_path/disksize" 2>/dev/null)
    else
        logger -p user.err -t zram-clean "[!] Error: Cannot determine total size of $zram_device"
        return 1
    fi
    
    # Obter uso atual (tentar diferentes caminhos para compatibilidade com diferentes versões do kernel)
    local used_size=0
    if [[ -f "$sys_path/mem_used_total" ]]; then
        used_size=$(cat "$sys_path/mem_used_total" 2>/dev/null)
    elif [[ -f "$sys_path/mm_stat" ]]; then
        # Em alguns kernels, as estatísticas estão em mm_stat (3ª coluna)
        used_size=$(awk '{print $3}' "$sys_path/mm_stat" 2>/dev/null)
    elif command -v zramctl >/dev/null 2>&1; then
        # Tentar com zramctl se disponível
        used_size=$(zramctl "$zram_device" --raw | awk '{print $4}' 2>/dev/null)
    else
        logger -p user.warn -t zram-clean "[!] Warning: Cannot determine exact usage, using directory size"
        # Fallback: Usar o tamanho do diretório (menos preciso)
        used_size=$(du -sb "$LOG_DIR" | awk '{print $1}' 2>/dev/null)
    fi
    
    # Calcular porcentagem
    if [[ $total_size -gt 0 && $used_size -gt 0 ]]; then
        echo $((used_size * 100 / total_size))
        return 0
    else
        logger -p user.err -t zram-clean "[!] Error: Invalid size values: total=$total_size, used=$used_size"
        return 1
    fi
}

# Limpar logs mais antigos até atingir o threshold desejado
clean_logs_to_threshold() {
    local current_usage=$1
    
    logger -p user.info -t zram-clean "[+] Current zram usage: $current_usage% (threshold: $THRESHOLD%)"
    
    if [[ $current_usage -le $THRESHOLD ]]; then
        logger -p user.info -t zram-clean "[✔] Usage is already below threshold, no cleaning needed"
        return 0
    fi
    
    # Listar todos os arquivos de log ordenados por data de modificação (mais antigos primeiro)
    local log_files=$(find "$LOG_DIR" -type f -name "*.log" -o -name "*.gz" | xargs ls -tr 2>/dev/null)
    
    # Se não encontrar arquivos de log específicos, considerar todos os arquivos
    if [[ -z "$log_files" ]]; then
        logger -p user.info -t zram-clean "[!] No *.log files found, considering all files in $LOG_DIR"
        log_files=$(find "$LOG_DIR" -type f | xargs ls -tr 2>/dev/null)
    fi
    
    # Se ainda não tiver arquivos, não há o que limpar
    if [[ -z "$log_files" ]]; then
        logger -p user.warn -t zram-clean "[!] No files found to clean in $LOG_DIR"
        return 1
    fi
    
    local files_cleaned=0
    local bytes_freed=0
    
    # Processar cada arquivo, do mais antigo para o mais recente
    for file in $log_files; do
        # Verificar a utilização atual
        zram_device=$(get_zram_device)
        current_usage=$(get_zram_usage_percent "$zram_device")
        
        # Se já estiver abaixo do threshold, parar
        if [[ $current_usage -le $THRESHOLD ]]; then
            break
        fi
        
        # Obter tamanho do arquivo antes de truncar
        local file_size=$(stat -c %s "$file" 2>/dev/null)
        if [[ -z "$file_size" ]]; then
            file_size=0
        fi
        
        # Truncar o arquivo
        logger -p user.info -t zram-clean "[+] Truncating file: $file (size: $(numfmt --to=iec $file_size 2>/dev/null || echo "$file_size"))"
        truncate -s 0 "$file" 2>/dev/null || rm -f "$file" 2>/dev/null
        
        # Contar estatísticas
        files_cleaned=$((files_cleaned + 1))
        bytes_freed=$((bytes_freed + file_size))
    done
    
    logger -p user.info -t zram-clean "[✔] Cleaned $files_cleaned files, freed approximately $(numfmt --to=iec $bytes_freed 2>/dev/null || echo "$bytes_freed") bytes"
    
    # Verificar se conseguimos ficar abaixo do threshold
    zram_device=$(get_zram_device)
    current_usage=$(get_zram_usage_percent "$zram_device")
    
    if [[ $current_usage -gt $THRESHOLD ]]; then
        logger -p user.warn -t zram-clean "[!] Warning: After cleaning, usage is still at $current_usage% (threshold: $THRESHOLD%)"
    else
        logger -p user.info -t zram-clean "[✔] Current usage now at $current_usage% (below threshold of $THRESHOLD%)"
    fi
    
    return 0
}

# Função principal
main() {
    # Verificar se o diretório existe
    if [[ ! -d "$LOG_DIR" ]]; then
        logger -p user.warn -t zram-clean "[!] Warning: Log directory $LOG_DIR does not exist. Creating it..."
        mkdir -p "$LOG_DIR"
    fi
    
    # Obter dispositivo zram
    zram_device=$(get_zram_device)
    if [[ $? -ne 0 ]]; then
        logger -p user.err -t zram-clean "[!] Error: Failed to find zram device"
        exit 1
    fi
    
    # Obter utilização atual
    current_usage=$(get_zram_usage_percent "$zram_device")
    if [[ $? -ne 0 ]]; then
        logger -p user.err -t zram-clean "[!] Error: Failed to determine zram usage"
        exit 1
    fi
    
    # Limpar logs se necessário
    clean_logs_to_threshold "$current_usage"
    
    logger -p user.info -t zram-clean "[✔] Zram log cleaning complete"
    exit 0
}

# Executar função principal
main