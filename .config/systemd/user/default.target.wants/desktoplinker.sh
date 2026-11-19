#!/usr/bin/env bash
# Generate KDE/XDG .desktop entries for AppImages in ~/Applications
set -u
shopt -s nullglob nocaseglob

APP_DIR="$HOME/Applications"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_DIR="$DATA/applications"
ICON_DIR="$DATA/icons/appimage"
mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

# --- Remove entries whose AppImage no longer exists ---
for d in "$DESKTOP_DIR"/appimage-*.desktop; do
    src=$(grep -m1 '^X-AppImage-Source=' "$d" | cut -d= -f2-)
    if [[ -n $src && ! -e $src ]]; then
        rm -f "$d" "$ICON_DIR/$(basename "${d%.desktop}" | sed 's/^appimage-//')".*
    fi
done

# --- Create/update entries ---
for f in "$APP_DIR"/*.AppImage; do
    [[ -x $f ]] || continue

    base=$(basename "$f"); base=${base%.*}
    id=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
    desktop="$DESKTOP_DIR/appimage-$id.desktop"

    # Skip if the entry is already newer than the AppImage
    [[ $desktop -nt $f ]] && continue

    tmp=$(mktemp -d)
    (
        cd "$tmp" || exit 1
        timeout 60 "$f" --appimage-extract '*.desktop' >/dev/null 2>&1
    )

    inner=("$tmp"/squashfs-root/*.desktop)   # root-level .desktop only
    name=""; icon=""; cats=""; comment=""
    if [[ -n ${inner[0]:-} ]]; then
        name=$(grep -m1 '^Name='       "${inner[0]}" | cut -d= -f2-)
        icon=$(grep -m1 '^Icon='       "${inner[0]}" | cut -d= -f2-)
        cats=$(grep -m1 '^Categories=' "${inner[0]}" | cut -d= -f2-)
        comment=$(grep -m1 '^Comment=' "${inner[0]}" | cut -d= -f2-)
    fi

    # Fallbacks
    [[ -z $name ]] && name=${base//[_]/ }
    [[ -z $cats ]] && cats="Utility;"

    # --- Icon extraction ---
    found=""
    pick_icon() {
        for ext in svg png xpm; do
            [[ -n $icon && -e $tmp/squashfs-root/$icon.$ext ]] && { found="$tmp/squashfs-root/$icon.$ext"; return; }
        done
        [[ -e $tmp/squashfs-root/.DirIcon ]] && { found="$tmp/squashfs-root/.DirIcon"; return; }
    }

    (cd "$tmp" && timeout 60 "$f" --appimage-extract '.DirIcon' >/dev/null 2>&1
     [[ -n $icon ]] && timeout 60 "$f" --appimage-extract "$icon.*" >/dev/null 2>&1)
    pick_icon

    # Dangling symlink or nothing found: pull the icon theme tree and take the largest PNG/SVG
    if [[ -z $found || ! -e $found ]]; then
        (cd "$tmp" && timeout 120 "$f" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1)
        found=$(find "$tmp/squashfs-root/usr/share/icons" \( -name "${icon:-*}.svg" -o -name "${icon:-*}.png" \) \
                -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    fi

    icon_value="application-x-executable"
    if [[ -n $found && -e $found ]]; then
        case $(file -bL --mime-type "$found") in
            image/svg*) ext=svg ;;
            image/png)  ext=png ;;
            image/x-xpixmap) ext=xpm ;;
            *) ext="" ;;
        esac
        if [[ -n $ext ]]; then
            cp -L "$found" "$ICON_DIR/$id.$ext" && icon_value="$ICON_DIR/$id.$ext"
        fi
    fi

    # --- Write the .desktop file ---
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=$name"
        [[ -n $comment ]] && echo "Comment=$comment"
        echo "Exec=\"$f\" %U"
        echo "Icon=$icon_value"
        echo "Terminal=false"
        echo "Categories=$cats"
        echo "X-AppImage-Source=$f"
    } > "$desktop"
    chmod +x "$desktop"

    rm -rf "$tmp"
done

command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null
exit 0
