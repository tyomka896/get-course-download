#!/bin/bash
set -eu
set +f

umask 0077

export TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Значения по умолчанию
HTML_FILE="index.html"
QUALITY=720

# Список допустипых значений качества видео
AVAILABLE_QUALITY=(360 480 720 1080)
AVAILABLE_QUALITY_STR=$(echo "${AVAILABLE_QUALITY[*]}" | sed 's/ /, /g')

# Текущие глобальные значения
html_file="$HTML_FILE"
video_name="${HTML_FILE%.*}"
quality=$QUALITY

log() {
    # echo "$(date '+%d.%m.%Y %H:%M:%S'): $1"
    echo "> $1"
}

press_to_continue() {
    echo
    read -p "Нажмите Enter, чтобы выйти. . ."
}

greeting_message() {
    echo "# Этот скрипт позволяет извлекать ссылки на видео из указанной HTML-страницы"
    echo "# и автоматически скачивать их на ваш компьютер."
    echo "# Укажите путь до HTML-страницы относительно текущего скрипта,"
    echo "# затем введите название видео для сохранения и желаемое качество скачивания."
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

# Запрос пути с именем HTML-документа
ask_html_page_name() {
    while true; do
        read -p "Введите название HTML-файла: " input

        input=$(echo "$input" | xargs)

        if [ -f "$input" ]; then
            html_file="$input"

            video_name="${html_file%.*}"
            video_name="${video_name:0:100}"

            break
        elif [ -z "$input" ]; then
            log "Внимание: название не может быть пустым"
        else
            log "Внимание: файл '$input' не найден"
        fi
    done
}

# Запрос имени видео для сохранения
ask_video_name() {
    while true; do
        read -rp "Название для сохранения (текущее: '$video_name'): " input

        input=$(echo "$input" | xargs)

        if [ -z "$input" ]; then
            break
        fi

        if [[ -n "$input" && ${#input} -lt 100 ]]; then
            video_name="$input"

            break
        fi

        log "Внимание: необходимо ввести строку длиной до 100 символов."
    done
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

    local base_url="$2/$QUALITY"

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
            log "Ошибка: фрагмент видео #$http_lines_count не удалось загрузить, повторите попытку позже"

            break
        fi

        show_progress "$line_count" "$http_lines_count"

        ((line_count++))
    done <"$playlist_path"

    echo
}

main() {
    ask_html_page_name

    local found_links=$(find_all_player_links | awk 'NF')
    local found_links_count=$(echo "$found_links" | grep -cve '^\s*$')

    if [ $found_links_count -eq 0 ]; then
        log "Внимание: ни одной ссылки на плеер не удалось найти, проверьте указанный файл"
        log "Или вероятно расположение ссылок на плеер у GetCourse.ru изменились"

        return
    fi

    log "Удалось найти ссылок на плеер: $found_links_count"

    ask_video_name
    ask_video_quality
    echo

    local media_count=1

    while IFS= read -r url; do
        save_video_as="$video_name"

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
            log "Вероятно HTML-страница устарела, скачайте ее снова"

            continue
        fi

        local media_url=$(find_media_quality "$playlist_url" | xargs)

        if [ -z "$media_url" ]; then
            log "Внимание: видео с качеством $quality не найден, попробуйте указать другое значение"

            continue
        fi

        download_video "$save_video_as" "$media_url"

        if [ $? -ne 0 ]; then
            log "Ошибка: загрузка видео '$file_name' предварительно завершилась с кодом $?"
        fi
    done <<<"$found_links"
}

greeting_message
main
echo

while true; do
    read -p "Повторить скачивание видео? (Да/нет): " answer

    answer="${answer,,}"
    letter="${answer:0:1}"

    if [[ "$letter" == "д" || "$letter" == "y" || -z "$letter" ]]; then
        echo
        main
        echo
    elif [[ "$letter" == "н" || "$letter" == "n" ]]; then
        break
    else
        log "Пожалуйста, ответьте 'да' или 'нет'"
    fi
done

# press_to_continue
