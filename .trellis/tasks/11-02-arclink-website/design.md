# Technical design

## Structure
Create an independent static site under `agent-bridge/website/` using HTML, CSS and a small ES module. No framework or runtime dependency is necessary for a single marketing page. Do not reuse the desktop application entry point because it depends on Tauri.

## Visual design
Use the existing ArcLink SVG logo, deep navy backgrounds, cyan/blue accents, generous spacing and restrained gradients. Organize the page as navigation, hero with device/product illustration, feature cards, three-step guide, downloads and footer. Build the illustrative device UI with HTML/CSS and label it as a product illustration. Responsive layouts collapse to a single column on phones.

## Download contract
Centralize platform/version/minimum OS/URL in a small configuration module. The Mac entry points to a same-site `downloads/ArcLink_0.1.0_aarch64.dmg` file. A documented preparation script copies the existing local package into the ignored downloads directory and fails clearly if absent. Verify byte equality against the source. Keep the binary out of Git; deployment instructions explicitly include the prepared file. iOS has a null URL and renders a plain unavailable status. Do not fabricate public URLs.

## Accessibility and operations
Use semantic HTML, real anchor links, visible keyboard focus, reduced-motion support and descriptive link text. Content remains readable if JavaScript is unavailable; provide a stable Mac download link in HTML with configuration kept consistent by the preparation workflow if needed. Serve locally with Python's static server. No backend, tracking or external fonts. Revert by removing the new website directory; native clients remain independent.

## Authorized production deployment
Add isolated Nginx vhost arclink.classktv.com to existing host 89.45.45.158. Release root /var/www/arclink/releases/<release>, current symlink /var/www/arclink/current, ACME webroot /var/www/arclink/acme. Bootstrap HTTP then issue domain certificate with existing Certbot and install HTTPS configuration. Upload only allowlisted static assets and deployment configuration; never vps.md. Test Nginx before reload and preserve other sites.
