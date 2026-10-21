# swift scripts/generate_app_icon.swift
# iconutil -c icns ./AppIcon.iconset --output Byakaron/Resources/AppIcon.icns

swift scripts/generate_icon_pdf.swift
mv ByakaronMenu.pdf Resources/ByakaronMenu.pdf

swift scripts/generate_icon.swift
mv ByakaronMenu.tiff Resources/ByakaronMenu.tiff