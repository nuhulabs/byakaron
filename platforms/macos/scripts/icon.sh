swift scripts/generate_app_icon.swift
iconutil -c icns ./AppIcon.iconset --output Byakaron/Resources/AppIcon.icns

swift scripts/generate_icon_pdf.swift
mv iconTemplate.pdf Byakaron/Resources/iconTemplate.pdf

swift scripts/generate_icon.swift
mv iconTemplate.tiff Byakaron/Resources/iconTemplate.tiff