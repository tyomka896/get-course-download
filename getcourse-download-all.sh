#!/bin/bash
set -eu
set +f

umask 0077

export TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Значения по умолчанию
QUALITY=720

# Список допустипых значений качества видео
AVAILABLE_QUALITY=(360 480 720 1080)
AVAILABLE_QUALITY_STR=$(echo "${AVAILABLE_QUALITY[*]}" | sed 's/ /, /g')

# Текущие глобальные значения
quality=$QUALITY

log() {
    # echo "$(date '+%d.%m.%Y %H:%M:%S'): $1"
    echo "> $1"
}

press_to_continue() {
    echo
    read -p "Нажми Enter, чтобы выйти. . ."
}

# Проверка наличия необходимых утилит
check_dependencies() {
    for cmd in curl awk grep gunzip sed; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Необходимая утилита $cmd не установлена. Пожалуйста, установите её." >&2
            exit 1
        }
    done
}

greeting_message() {
    echo "# Этот скрипт позволяет извлекать ссылки на видео из HTML-страниц,"
    echo "# которые находятся в текущей директории скрипта"
    echo "# и автоматически скачивать их на твой компьютер."
    echo
}

show_progress() {
    local percent=$(($1 * 100 / $2))

    printf "\r["
    for ((j = 0; j < percent / 2; j++)); do
        printf "="
    done
    for ((j = percent / 2; j < 50; j++)); do
        printf " "
    done
    printf "] %d%%" "$percent"
}

# Запрос качества видео
ask_video_quality() {
    while true; do
        read -rp "Качество видео (текущее: $quality): " input

        input=$(echo "$input" | xargs)

        if [ -z "$input" ]; then
            break
        fi

        if [[ " ${AVAILABLE_QUALITY[@]} " =~ " $input " ]]; then
            quality="$input"

            break
        fi

        log "Внимание: допустимые значения качества: $AVAILABLE_QUALITY_STR."
    done
}

# Поиск ссылок для плееры на странице
find_all_player_links() {
    html_file="$1"

    # Это вполне прямой подход подиска ссылок на HTML-документе
    # Поиск ссылки плеера в теге <iframe src="link" . . .></iframe>
    # Попытка найти все значения link в документе
    iframe_result="$(awk '
    /<iframe/{flag=1}
    flag && /src=["]/ {
        match($0, /src=["]([^"]*)/, arr);
        if (arr[1] != "") {
            print arr[1];
        }
    }
    /<\/iframe>/{flag=0}' "$html_file")"

    # Ниже можно добавить другой способ поиска ссылок на плеер
    # И результатом конкатинировать все полученные значения новой строкой
    another_one=$(echo -n "")

    printf "%b\n%b" "$iframe_result" "$another_one"
}

# Запрос страницы плеера, который форматирован gzip
# $1 - URL-адрес на плеер
curl_gzip() {
    local url="$1"
    local domain=$(echo "$url" | cut -d'/' -f3)

    local file_gzip=$(mktemp)
    local file_html=$(mktemp)

    curl -sLX GET "$url" -H "Accept-Encoding:gzip,deflate" -H "Host:$domain" -o "$file_gzip"

    if [ $? -ne 0 ]; then
        # log "Ошибка: -"

        return
    fi

    gunzip -c "$file_gzip" >"$file_html"

    echo "$file_html"
}

# Поиск полного адреса до списка качества видео
# $1 - HTML-документ с метаданными плеера
find_playlist_url() {
    local file_html="$1"

    # Полный URL-адрес лежит в JSON поле masterPlaylistUrl
    matser_url=$(grep -Po '"masterPlaylistUrl": *"\K[^"]*' "$file_html" | cut -d '?' -f 1 | sed 's/\\\//\//g')

    # Ниже можно добавить другой способ поиска ссылки на список качеств
    # И результатом конкатинировать все полученные значения новой строкой
    another_one=$(echo -n "")

    printf "%b\n%b" "$matser_url" "$another_one"
}

# Поиск выбранного качества видео в плейлисте
# $1 - URL-адрес на плейлист
find_media_quality() {
    local playlist_url="$1"

    local quality_urls=$(curl -sLX GET "$playlist_url")

    echo "$quality_urls" | grep "RESOLUTION=.*x${quality}" -A 1 | grep -v "RESOLUTION"
}

# Скачивание всех фрагментов видео воедино
# $1 - имя файла для сохранения
# $2 - URL-адрес со всеми фрагментами видео
download_video() {
    local file_name="$1.ts"

    if [ -f "$file_name" ] && [ -s "$file_name" ]; then
        log "Файл '$file_name' уже существует, загрузка пропущена"

        return
    fi

    local playlist_path=$(mktemp)

    local base_url="$2/$quality"

    curl -sLo "$playlist_path" "$base_url"

    local line_count=1

    local http_lines_count=$(grep -E '^http' $playlist_path | wc -l)

    if [ "$http_lines_count" -eq 0 ]; then
        log "Ошибка: Фрагменты видео не обнаружены, вероятно в связи обновлением версии GetCourse.ru"

        return
    fi

    show_progress 0 "$http_lines_count"

    while IFS= read -r line; do
        if [[ $line != http* ]]; then
            continue
        fi

        curl --retry 3 -sL "$line" >>"$file_name"

        if [ $? -ne 0 ]; then
            log "Ошибка: фрагмент видео #$http_lines_count не удалось загрузить, повтори попытку позже"

            break
        fi

        show_progress "$line_count" "$http_lines_count"

        ((line_count++))
    done <"$playlist_path"

    echo
}

download_all_links() {
    local found_links=$1
    local save_as=$2

    local found_links_count=$(echo "$found_links" | grep -cve '^\s*$')

    if [ $found_links_count -eq 0 ]; then
        log "Внимание: ни одной ссылки на плеер не удалось найти, проверь указанный файл"
        log "Или вероятно расположение ссылок на плеер у GetCourse.ru изменились"

        return
    fi

    log "Удалось найти ссылок на плеер: $found_links_count"

    local media_count=1

    while IFS= read -r url; do
        save_video_as="$save_as"

        if [ $found_links_count -gt 1 ]; then
            save_video_as="$save_video_as $media_count"
        fi

        log "Подготовка к загрузке видео '$save_video_as'. . ."

        ((media_count++))

        local file_html=$(curl_gzip "$url")

        if [ ! -f "$file_html" ]; then
            log "Внимание: плеер не опознан, возможно ссылка не пренадлежит GetCourse.ru"

            continue
        fi

        local playlist_url=$(find_playlist_url "$file_html" | xargs)

        if [ -z "$playlist_url" ]; then
            log "Внимание: список вариантов качества видео не удалось получить"
            log "Вероятно HTML-страница устарела, скачай ее снова"

            continue
        fi

        local media_url=$(find_media_quality "$playlist_url" | xargs)

        if [ -z "$media_url" ]; then
            log "Внимание: видео с качеством $quality не найден, попробуй указать другое значение"

            continue
        fi

        download_video "$save_video_as" "$media_url"

        if [ $? -ne 0 ]; then
            log "Ошибка: загрузка видео '$file_name' предварительно завершилась с кодом $?"
        fi
    done <<<"$found_links"
}

main() {
    local html_files=$(find . -maxdepth 1 -type f -name "*.html" -print)

    while read -r html_file; do
        log "Обработка файла: $html_file"

        local found_links=$(find_all_player_links "$html_file" | awk 'NF')

        local video_name="${html_file%.*}"
        local video_name="${video_name:0:100}"

        download_all_links "$found_links" "$video_name"

        echo
    done <<<"$html_files"
}

check_dependencies
greeting_message
ask_video_quality
echo
main
