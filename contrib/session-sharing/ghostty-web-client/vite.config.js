import { defineConfig } from "vite";

// Split the production bundle so the rarely-changing `ghostty-web` library
// (~150 KB gzip) and the tiny Capacitor runtime live in their own
// long-cached chunks. Without this everything ends up in a single
// ~200 KB gzip chunk whose hash flips on every app-code edit, forcing
// browsers to re-download the library too. APK builds are unaffected —
// dist/ ships as local assets either way.
export default defineConfig({
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          "ghostty-web": ["ghostty-web"],
          capacitor: ["@capacitor/core", "@capacitor/app"],
        },
      },
    },
  },
});
