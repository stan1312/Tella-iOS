export default [{
  files: ["**/*.js"],
  languageOptions: { ecmaVersion: 2019, sourceType: "script", globals: {
    PropertiesService: "readonly", CacheService: "readonly", LockService: "readonly", UrlFetchApp: "readonly",
    Utilities: "readonly", ContentService: "readonly", ScriptApp: "readonly", console: "readonly" } },
  rules: { "no-undef": "off", "no-unused-vars": "off", "eqeqeq": "error", "no-eval": "error", "no-implied-eval": "error", "no-new-func": "error", "no-redeclare": "error", "no-dupe-keys": "error", "no-unreachable": "error" }
}];
