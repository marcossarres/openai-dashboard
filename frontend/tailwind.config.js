/** @type {import('tailwindcss').Config} */
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        accent: '#00d4aa',
        'accent-dark': '#00a882',
      },
    },
  },
  plugins: [],
};
