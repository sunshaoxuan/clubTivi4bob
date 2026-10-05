# Self-hosted dependencies

Runtime files are copied unmodified from the official npm distributions:

- Three.js 0.180.0: three.module.js, three.core.js, RoundedBoxGeometry, RoomEnvironment. MIT license in THREE-LICENSE.txt.
- GSAP 3.13.0: gsap.min.js and ScrollTrigger.min.js. Distribution license notice is retained in both files. Standard no-charge license: https://gsap.com/standard-license/ .
- Lucide 0.468.0: UMD lucide.min.js. ISC license in LUCIDE-LICENSE.txt.

The page uses local URLs for every runtime dependency, texture and icon.
No npm build or CDN access is required by visitors. Temporary npm installation
files are excluded from version control and removed after validation.
