// Tailwind is for the docs only: app/(docs)/docs.css imports it, the product page's CSS does not.
const config = {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};

export default config;
