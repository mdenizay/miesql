import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri serves the frontend from a fixed port in development and from `dist` in a build.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 5173,
    strictPort: true,
    watch: {
      // The Rust side has its own rebuild loop; watching it here just wastes cycles.
      ignored: ["**/src-tauri/**"],
    },
  },
  build: {
    // Matches the oldest WebView each platform ships: WKWebView, WebView2, WebKitGTK.
    target: ["es2021", "chrome100", "safari15"],
    sourcemap: false,
    minify: "esbuild",
  },
});
