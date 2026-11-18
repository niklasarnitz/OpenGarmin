import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Relative asset paths: the Vapor server serves dist/ from its Public/ directory at the site root.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    chunkSizeWarningLimit: 1500,
  },
  test: {
    include: ["src/**/*.test.ts"],
  },
});
