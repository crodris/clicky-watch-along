// Vite's `?raw` suffix imports a file as its text. Only tests use it, to read the app's page scripts.
declare module "*?raw" {
  const fileText: string;
  export default fileText;
}
