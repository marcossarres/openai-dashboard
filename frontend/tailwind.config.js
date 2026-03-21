/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        accent: '#00d4aa',
        'accent-dark': '#00a882',
        surface: '#141414',
        border: '#222',
      },
    },
  },
  plugins: [],
};
