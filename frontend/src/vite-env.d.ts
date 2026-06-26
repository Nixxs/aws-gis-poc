/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_PMTILES_BASE: string;
  readonly VITE_QUERY_API: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
