# Include inside the existing BobTV HTTPS server block only.
# This preview is separate from /opt/bobtv/site and the running API process.
location = /new {
    return 307 /new/;
}
location ^~ /new/ {
    alias /opt/bobtv/new/;
    index index.html;
    autoindex off;
    add_header Cache-Control "no-cache" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
}
