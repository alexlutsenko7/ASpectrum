# Generators for the Word documents in docs/

Needs Node.js with the `docx` npm package (`npm install docx` in a scratch folder, run from there).
Paper: US Letter, 1-inch margins.

    node keys_doc.js ../ASpectrum_Keys.docx
    python3 architecture_diagram.py ../../ASpectrum/rtl/osd_font.hex arch.png   # block diagram, Spectrum font
    node architecture_doc.js ../ASpectrum_Architecture.docx arch.png
