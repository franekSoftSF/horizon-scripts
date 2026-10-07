# shellcheck shell=bash
# Mode "courses": one "Courses" folder for the course applications (GNU Octave, Gnumeric,
# Qt Creator, VS Code, Texmaker, TeXstudio, texdoctk, Eclipse, ...), on GNOME and MATE.
#   GNOME  app-grid folder through the dconf system database (org.gnome.desktop.app-folders);
#          apps in a folder leave the main grid. Locked by default, so lab users always see it.
#   MATE   XDG submenu "Courses" with the usual sub-categories inside (Programming,
#          Education, Office, Graphics, Other - taken from each app's own Categories), e.g.
#          Courses > Programming > Geany, Jupyter, Qt Creator, VS Code, Eclipse. The apps are
#          moved by an override copy of their .desktop file in /usr/local/share/applications
#          with Categories=X-VDI-Apps;X-VDI-<group>; (package files untouched).
#   GNOME  folders cannot be nested there: one flat folder.
# Everything is tracked in courses-state.json: each run first removes the previous result, so
# apps dropped from COURSES_APPS disappear; "courses --revert" removes it all. Re-run by
# "apps" and "update" so the override copies follow package updates.

MENU_OVERRIDE_DIR="/usr/local/share/applications"
MENU_XDG_FILE="/etc/xdg/menus/applications-merged/vdi-courses.menu"
MENU_DIRECTORY_FILE="/usr/share/desktop-directories/vdi-courses.directory"
MENU_DCONF_FILE="/etc/dconf/db/local.d/70-vdi-imagemaint-courses"
MENU_DCONF_LOCKS="/etc/dconf/db/local.d/locks/70-vdi-imagemaint-courses"
MENU_GNOME_FOLDER="VDI-Courses"

# menu_find_apps -> desktop file ids (one per line) matching COURSES_APPS.
# An entry ending in .desktop is an exact id, anything else a case-insensitive part of
# the file name. Hidden entries (NoDisplay=true) are skipped. Eclipse is added when present.
menu_find_apps() {
    local pat f id seen=" "
    for pat in $COURSES_APPS vdi-eclipse.desktop; do
        while IFS= read -r f; do
            [[ -f $f ]] || continue
            grep -qiE '^NoDisplay[[:space:]]*=[[:space:]]*true' "$f" && continue
            id=$(basename "$f")
            [[ $seen == *" $id "* ]] && continue
            seen+="$id "
            printf '%s\n' "$id"
        done < <(
            if [[ $pat == *.desktop ]]; then
                ls -1 "/usr/share/applications/${pat}" 2>/dev/null || true
            else
                find /usr/share/applications -maxdepth 1 -type f -iname "*${pat}*.desktop" 2>/dev/null | sort || true
            fi
        )
    done
}

# Sub-category of an app, like the MATE menu places it (first match wins).
COURSES_GROUPS="programming education office graphics other"
courses_group() {
    local c
    c=$(sed -nE 's/^Categories[[:space:]]*=[[:space:]]*//p' "$1" 2>/dev/null | head -n1 || true)
    case ";${c}" in
        *";Development;"*) echo programming ;;
        *";Education;"* | *";Science;"* | *";Math;"* | *";Chemistry;"* | *";Physics;"*) echo education ;;
        *";Office;"* | *";Publishing;"* | *";Spreadsheet;"* | *";WordProcessor;"*) echo office ;;
        *";Graphics;"*) echo graphics ;;
        *) echo other ;;
    esac
}

# Display names of the sub-menus (EN, PL)
courses_group_name() {
    case $1 in
        programming) printf 'Programming\tProgramowanie' ;;
        education) printf 'Education\tEdukacja' ;;
        office) printf 'Office\tBiuro' ;;
        graphics) printf 'Graphics\tGrafika' ;;
        *) printf 'Other\tInne' ;;
    esac
}

# GNOME default folders (keep them next to ours)
menu_gnome_children() {
    local cur
    cur=$(gsettings get org.gnome.desktop.app-folders folder-children 2>/dev/null || true)
    [[ $cur == \[* ]] || cur="['Utilities', 'YaST']"
    cur=${cur#@as }
    if [[ $cur == *"'${MENU_GNOME_FOLDER}'"* ]]; then
        printf '%s' "$cur"
    elif [[ $cur == "[]" ]]; then
        printf "['%s']" "$MENU_GNOME_FOLDER"
    else
        printf "['%s', %s" "$MENU_GNOME_FOLDER" "${cur#[}"
    fi
}

mode_courses() {
    if [[ ${REVERT:-0} == 1 ]]; then
        logt STEP step_courses_revert
        files_restore courses
        menu_refresh
        logt OK courses_reverted
        return 0
    fi
    logt STEP step_courses
    local -a ids=()
    local id
    while IFS= read -r id; do ids+=("$id"); done < <(menu_find_apps)
    # Start from a clean slate: apps removed from COURSES_APPS must leave the folder.
    files_restore courses >/dev/null 2>&1 || true
    if ((${#ids[@]} == 0)); then
        logt WARN courses_no_apps "$COURSES_APPS"
        menu_refresh
        return 0
    fi
    logt INFO courses_apps "${#ids[@]}" "${ids[*]}"

    # Folder name, translated (GNOME reads it from the .directory file with translate=true).
    write_file courses "$MENU_DIRECTORY_FILE" 0644 <<EOF
[Desktop Entry]
Type=Directory
Name=${COURSES_FOLDER_NAME}
Name[pl]=${COURSES_FOLDER_NAME_PL:-$COURSES_FOLDER_NAME}
Icon=applications-science
EOF

    # MATE / XDG menus: override copies with our categories, plus the merged submenu with
    # one sub-menu per group that has apps.
    local src group en pl
    declare -A in_group=()
    for id in "${ids[@]}"; do
        src="/usr/share/applications/${id}"
        group=$(courses_group "$src")
        in_group[$group]+="${id} "
        sed -E -e '/^Categories[[:space:]]*=/d' \
            -e "0,/^\[Desktop Entry\]/s//[Desktop Entry]\nCategories=X-VDI-Apps;X-VDI-${group};/" "$src" |
            write_file courses "${MENU_OVERRIDE_DIR}/${id}" 0644
    done
    for group in $COURSES_GROUPS; do
        [[ -n ${in_group[$group]:-} ]] || continue
        IFS=$'\t' read -r en pl <<<"$(courses_group_name "$group")"
        write_file courses "/usr/share/desktop-directories/vdi-courses-${group}.directory" 0644 <<EOF
[Desktop Entry]
Type=Directory
Name=${en}
Name[pl]=${pl}
Icon=applications-$([[ $group == programming ]] && echo development || echo "$group")
EOF
    done
    {
        cat <<'EOF'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<!-- Managed by VDI-ImageMaint (mode courses); the revert option of that mode removes it. -->
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>VDI-Apps</Name>
    <Directory>vdi-courses.directory</Directory>
EOF
        for group in $COURSES_GROUPS; do
            [[ -n ${in_group[$group]:-} ]] || continue
            printf '    <Menu>\n      <Name>VDI-Courses-%s</Name>\n      <Directory>vdi-courses-%s.directory</Directory>\n      <Include>\n        <Category>X-VDI-%s</Category>\n' \
                "$group" "$group" "$group"
            for id in ${in_group[$group]}; do printf '        <Filename>%s</Filename>\n' "$id"; done
            printf '      </Include>\n    </Menu>\n'
        done
        cat <<'EOF'
  </Menu>
</Menu>
EOF
    } | write_file courses "$MENU_XDG_FILE" 0644

    # GNOME app-grid folder (system default for every user; locked unless COURSES_LOCK=no).
    local apps="" children
    for id in "${ids[@]}"; do apps+="${apps:+, }'${id}'"; done
    children=$(menu_gnome_children)
    if [[ ! -f /etc/dconf/profile/user ]]; then
        printf 'user-db:user\nsystem-db:local\n' | write_file build /etc/dconf/profile/user 0644
    fi
    write_file courses "$MENU_DCONF_FILE" 0644 <<EOF
${MANAGED_MARK}
[org/gnome/desktop/app-folders]
folder-children=${children}

[org/gnome/desktop/app-folders/folders/${MENU_GNOME_FOLDER}]
name='vdi-courses.directory'
translate=true
apps=[${apps}]
EOF
    if [[ $COURSES_LOCK == yes ]]; then
        write_file courses "$MENU_DCONF_LOCKS" 0644 <<EOF
/org/gnome/desktop/app-folders/folder-children
/org/gnome/desktop/app-folders/folders/${MENU_GNOME_FOLDER}/apps
/org/gnome/desktop/app-folders/folders/${MENU_GNOME_FOLDER}/name
EOF
    fi
    menu_refresh
    logt OK courses_done "$COURSES_FOLDER_NAME" "${#ids[@]}"
}

menu_refresh() {
    if command -v dconf >/dev/null 2>&1; then
        run dconf update || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        run update-desktop-database "$MENU_OVERRIDE_DIR" 2>/dev/null || true
    fi
    return 0
}
