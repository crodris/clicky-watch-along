#!/bin/sh
# The "Copy Bundled Themes" Xcode build phase of the leanring-buddy target. It copies each .clickytheme package in
# themes/ into Clicky.app/Contents/Resources/Themes, which BundledThemes.directoryURL reads. Xcode's synchronized folders
# copy every file to the top of Resources, so eleven theme.json files there would collide, and the packages live outside
# leanring-buddy/ for that reason. Only theme.json is copied: the roster portraits stay in the gitignored
# leanring-buddy/HaikyuPortraits, which Xcode copies to the top of Resources, where a bundled roster looks them up.
set -eu

themes_source="${SRCROOT:?}/themes"
themes_destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Themes"

# The folder is deleted and made again on each build, so the guard names what the delete may touch: the app's own Themes
# folder, and nothing an empty build setting could turn the path into.
case "$themes_destination" in
  *.app/Contents/Resources/Themes) ;;
  *) echo "copy-bundled-themes: refusing to replace $themes_destination, which is not an app's Contents/Resources/Themes" >&2; exit 1 ;;
esac
rm -rf "$themes_destination"
/bin/mkdir -p "$themes_destination"
for theme_package in "$themes_source"/*.clickytheme; do
  package_name="$(basename "$theme_package")"
  /bin/mkdir "$themes_destination/$package_name"
  cp "$theme_package/theme.json" "$themes_destination/$package_name/theme.json"
done
echo "Copied $(ls -d "$themes_destination"/*.clickytheme | wc -l | tr -d ' ') bundled themes to $themes_destination"
