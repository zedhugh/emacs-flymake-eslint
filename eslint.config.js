const js = require("@eslint/js");

/**
 * @type {import("eslint").Linter.Config[]}
 */
module.exports = [
  // { globals: { require: false } },
  // js.configs.recommended,
  {
    rules: {
      "no-console": "error",
      "no-await-in-loop": "warn",
      "array-callback-return": "error",
    },
  },
];
