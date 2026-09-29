var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __commonJS = (cb, mod) => function __require() {
  try {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  } catch (e) {
    throw mod = 0, e;
  }
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// node_modules/semver/internal/constants.js
var require_constants = __commonJS({
  "node_modules/semver/internal/constants.js"(exports, module) {
    "use strict";
    var SEMVER_SPEC_VERSION = "2.0.0";
    var MAX_LENGTH = 256;
    var MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER || /* istanbul ignore next */
    9007199254740991;
    var MAX_SAFE_COMPONENT_LENGTH = 16;
    var MAX_SAFE_BUILD_LENGTH = MAX_LENGTH - 6;
    var RELEASE_TYPES = [
      "major",
      "premajor",
      "minor",
      "preminor",
      "patch",
      "prepatch",
      "prerelease"
    ];
    module.exports = {
      MAX_LENGTH,
      MAX_SAFE_COMPONENT_LENGTH,
      MAX_SAFE_BUILD_LENGTH,
      MAX_SAFE_INTEGER,
      RELEASE_TYPES,
      SEMVER_SPEC_VERSION,
      FLAG_INCLUDE_PRERELEASE: 1,
      FLAG_LOOSE: 2
    };
  }
});

// node_modules/semver/internal/debug.js
var require_debug = __commonJS({
  "node_modules/semver/internal/debug.js"(exports, module) {
    "use strict";
    var debug = typeof process === "object" && process.env && process.env.NODE_DEBUG && /\bsemver\b/i.test(process.env.NODE_DEBUG) ? (...args) => console.error("SEMVER", ...args) : () => {
    };
    module.exports = debug;
  }
});

// node_modules/semver/internal/re.js
var require_re = __commonJS({
  "node_modules/semver/internal/re.js"(exports, module) {
    "use strict";
    var {
      MAX_SAFE_COMPONENT_LENGTH,
      MAX_SAFE_BUILD_LENGTH,
      MAX_LENGTH
    } = require_constants();
    var debug = require_debug();
    exports = module.exports = {};
    var re = exports.re = [];
    var safeRe = exports.safeRe = [];
    var src = exports.src = [];
    var safeSrc = exports.safeSrc = [];
    var t = exports.t = {};
    var R = 0;
    var LETTERDASHNUMBER = "[a-zA-Z0-9-]";
    var safeRegexReplacements = [
      ["\\s", 1],
      ["\\d", MAX_LENGTH],
      [LETTERDASHNUMBER, MAX_SAFE_BUILD_LENGTH]
    ];
    var makeSafeRegex = (value) => {
      for (const [token, max] of safeRegexReplacements) {
        value = value.split(`${token}*`).join(`${token}{0,${max}}`).split(`${token}+`).join(`${token}{1,${max}}`);
      }
      return value;
    };
    var createToken = (name, value, isGlobal) => {
      const safe = makeSafeRegex(value);
      const index = R++;
      debug(name, index, value);
      t[name] = index;
      src[index] = value;
      safeSrc[index] = safe;
      re[index] = new RegExp(value, isGlobal ? "g" : void 0);
      safeRe[index] = new RegExp(safe, isGlobal ? "g" : void 0);
    };
    createToken("NUMERICIDENTIFIER", "0|[1-9]\\d*");
    createToken("NUMERICIDENTIFIERLOOSE", "\\d+");
    createToken("NONNUMERICIDENTIFIER", `\\d*[a-zA-Z-]${LETTERDASHNUMBER}*`);
    createToken("MAINVERSION", `(${src[t.NUMERICIDENTIFIER]})\\.(${src[t.NUMERICIDENTIFIER]})\\.(${src[t.NUMERICIDENTIFIER]})`);
    createToken("MAINVERSIONLOOSE", `(${src[t.NUMERICIDENTIFIERLOOSE]})\\.(${src[t.NUMERICIDENTIFIERLOOSE]})\\.(${src[t.NUMERICIDENTIFIERLOOSE]})`);
    createToken("PRERELEASEIDENTIFIER", `(?:${src[t.NONNUMERICIDENTIFIER]}|${src[t.NUMERICIDENTIFIER]})`);
    createToken("PRERELEASEIDENTIFIERLOOSE", `(?:${src[t.NONNUMERICIDENTIFIER]}|${src[t.NUMERICIDENTIFIERLOOSE]})`);
    createToken("PRERELEASE", `(?:-(${src[t.PRERELEASEIDENTIFIER]}(?:\\.${src[t.PRERELEASEIDENTIFIER]})*))`);
    createToken("PRERELEASELOOSE", `(?:-?(${src[t.PRERELEASEIDENTIFIERLOOSE]}(?:\\.${src[t.PRERELEASEIDENTIFIERLOOSE]})*))`);
    createToken("BUILDIDENTIFIER", `${LETTERDASHNUMBER}+`);
    createToken("BUILD", `(?:\\+(${src[t.BUILDIDENTIFIER]}(?:\\.${src[t.BUILDIDENTIFIER]})*))`);
    createToken("FULLPLAIN", `v?${src[t.MAINVERSION]}${src[t.PRERELEASE]}?${src[t.BUILD]}?`);
    createToken("FULL", `^${src[t.FULLPLAIN]}$`);
    createToken("LOOSEPLAIN", `[v=\\s]*${src[t.MAINVERSIONLOOSE]}${src[t.PRERELEASELOOSE]}?${src[t.BUILD]}?`);
    createToken("LOOSE", `^${src[t.LOOSEPLAIN]}$`);
    createToken("GTLT", "((?:<|>)?=?)");
    createToken("XRANGEIDENTIFIERLOOSE", `${src[t.NUMERICIDENTIFIERLOOSE]}|x|X|\\*`);
    createToken("XRANGEIDENTIFIER", `${src[t.NUMERICIDENTIFIER]}|x|X|\\*`);
    createToken("XRANGEPLAIN", `[v=\\s]*(${src[t.XRANGEIDENTIFIER]})(?:\\.(${src[t.XRANGEIDENTIFIER]})(?:\\.(${src[t.XRANGEIDENTIFIER]})(?:${src[t.PRERELEASE]})?${src[t.BUILD]}?)?)?`);
    createToken("XRANGEPLAINLOOSE", `[v=\\s]*(${src[t.XRANGEIDENTIFIERLOOSE]})(?:\\.(${src[t.XRANGEIDENTIFIERLOOSE]})(?:\\.(${src[t.XRANGEIDENTIFIERLOOSE]})(?:${src[t.PRERELEASELOOSE]})?${src[t.BUILD]}?)?)?`);
    createToken("XRANGE", `^${src[t.GTLT]}\\s*${src[t.XRANGEPLAIN]}$`);
    createToken("XRANGELOOSE", `^${src[t.GTLT]}\\s*${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("COERCEPLAIN", `${"(^|[^\\d])(\\d{1,"}${MAX_SAFE_COMPONENT_LENGTH}})(?:\\.(\\d{1,${MAX_SAFE_COMPONENT_LENGTH}}))?(?:\\.(\\d{1,${MAX_SAFE_COMPONENT_LENGTH}}))?`);
    createToken("COERCE", `${src[t.COERCEPLAIN]}(?:$|[^\\d])`);
    createToken("COERCEFULL", src[t.COERCEPLAIN] + `(?:${src[t.PRERELEASE]})?(?:${src[t.BUILD]})?(?:$|[^\\d])`);
    createToken("COERCERTL", src[t.COERCE], true);
    createToken("COERCERTLFULL", src[t.COERCEFULL], true);
    createToken("LONETILDE", "(?:~>?)");
    createToken("TILDETRIM", `(\\s*)${src[t.LONETILDE]}\\s+`, true);
    exports.tildeTrimReplace = "$1~";
    createToken("TILDE", `^${src[t.LONETILDE]}${src[t.XRANGEPLAIN]}$`);
    createToken("TILDELOOSE", `^${src[t.LONETILDE]}${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("LONECARET", "(?:\\^)");
    createToken("CARETTRIM", `(\\s*)${src[t.LONECARET]}\\s+`, true);
    exports.caretTrimReplace = "$1^";
    createToken("CARET", `^${src[t.LONECARET]}${src[t.XRANGEPLAIN]}$`);
    createToken("CARETLOOSE", `^${src[t.LONECARET]}${src[t.XRANGEPLAINLOOSE]}$`);
    createToken("COMPARATORLOOSE", `^${src[t.GTLT]}\\s*(${src[t.LOOSEPLAIN]})$|^$`);
    createToken("COMPARATOR", `^${src[t.GTLT]}\\s*(${src[t.FULLPLAIN]})$|^$`);
    createToken("COMPARATORTRIM", `(\\s*)${src[t.GTLT]}\\s*(${src[t.LOOSEPLAIN]}|${src[t.XRANGEPLAIN]})`, true);
    exports.comparatorTrimReplace = "$1$2$3";
    createToken("HYPHENRANGE", `^\\s*(${src[t.XRANGEPLAIN]})\\s+-\\s+(${src[t.XRANGEPLAIN]})\\s*$`);
    createToken("HYPHENRANGELOOSE", `^\\s*(${src[t.XRANGEPLAINLOOSE]})\\s+-\\s+(${src[t.XRANGEPLAINLOOSE]})\\s*$`);
    createToken("STAR", "(<|>)?=?\\s*\\*");
    createToken("GTE0", "^\\s*>=\\s*0\\.0\\.0\\s*$");
    createToken("GTE0PRE", "^\\s*>=\\s*0\\.0\\.0-0\\s*$");
  }
});

// node_modules/semver/internal/parse-options.js
var require_parse_options = __commonJS({
  "node_modules/semver/internal/parse-options.js"(exports, module) {
    "use strict";
    var looseOption = Object.freeze({ loose: true });
    var emptyOpts = Object.freeze({});
    var parseOptions = (options) => {
      if (!options) {
        return emptyOpts;
      }
      if (typeof options !== "object") {
        return looseOption;
      }
      return options;
    };
    module.exports = parseOptions;
  }
});

// node_modules/semver/internal/identifiers.js
var require_identifiers = __commonJS({
  "node_modules/semver/internal/identifiers.js"(exports, module) {
    "use strict";
    var numeric = /^[0-9]+$/;
    var compareIdentifiers = (a, b) => {
      if (typeof a === "number" && typeof b === "number") {
        return a === b ? 0 : a < b ? -1 : 1;
      }
      const anum = numeric.test(a);
      const bnum = numeric.test(b);
      if (anum && bnum) {
        a = +a;
        b = +b;
      }
      return a === b ? 0 : anum && !bnum ? -1 : bnum && !anum ? 1 : a < b ? -1 : 1;
    };
    var rcompareIdentifiers = (a, b) => compareIdentifiers(b, a);
    module.exports = {
      compareIdentifiers,
      rcompareIdentifiers
    };
  }
});

// node_modules/semver/classes/semver.js
var require_semver = __commonJS({
  "node_modules/semver/classes/semver.js"(exports, module) {
    "use strict";
    var debug = require_debug();
    var { MAX_LENGTH, MAX_SAFE_INTEGER } = require_constants();
    var { safeRe: re, t } = require_re();
    var parseOptions = require_parse_options();
    var { compareIdentifiers } = require_identifiers();
    var isPrereleaseIdentifier = (prerelease2, identifier) => {
      const identifiers = identifier.split(".");
      if (identifiers.length > prerelease2.length) {
        return false;
      }
      for (let i = 0; i < identifiers.length; i++) {
        if (compareIdentifiers(prerelease2[i], identifiers[i]) !== 0) {
          return false;
        }
      }
      return true;
    };
    var SemVer = class _SemVer {
      constructor(version, options) {
        options = parseOptions(options);
        if (version instanceof _SemVer) {
          if (version.loose === !!options.loose && version.includePrerelease === !!options.includePrerelease) {
            return version;
          } else {
            version = version.version;
          }
        } else if (typeof version !== "string") {
          throw new TypeError(`Invalid version. Must be a string. Got type "${typeof version}".`);
        }
        if (version.length > MAX_LENGTH) {
          throw new TypeError(
            `version is longer than ${MAX_LENGTH} characters`
          );
        }
        debug("SemVer", version, options);
        this.options = options;
        this.loose = !!options.loose;
        this.includePrerelease = !!options.includePrerelease;
        const m = version.trim().match(options.loose ? re[t.LOOSE] : re[t.FULL]);
        if (!m) {
          throw new TypeError(`Invalid Version: ${version}`);
        }
        this.raw = version;
        this.major = +m[1];
        this.minor = +m[2];
        this.patch = +m[3];
        if (this.major > MAX_SAFE_INTEGER || this.major < 0) {
          throw new TypeError("Invalid major version");
        }
        if (this.minor > MAX_SAFE_INTEGER || this.minor < 0) {
          throw new TypeError("Invalid minor version");
        }
        if (this.patch > MAX_SAFE_INTEGER || this.patch < 0) {
          throw new TypeError("Invalid patch version");
        }
        if (!m[4]) {
          this.prerelease = [];
        } else {
          this.prerelease = m[4].split(".").map((id) => {
            if (/^[0-9]+$/.test(id)) {
              const num = +id;
              if (num >= 0 && num < MAX_SAFE_INTEGER) {
                return num;
              }
            }
            return id;
          });
        }
        this.build = m[5] ? m[5].split(".") : [];
        this.format();
      }
      format() {
        this.version = `${this.major}.${this.minor}.${this.patch}`;
        if (this.prerelease.length) {
          this.version += `-${this.prerelease.join(".")}`;
        }
        return this.version;
      }
      toString() {
        return this.version;
      }
      compare(other) {
        debug("SemVer.compare", this.version, this.options, other);
        if (!(other instanceof _SemVer)) {
          if (typeof other === "string" && other === this.version) {
            return 0;
          }
          other = new _SemVer(other, this.options);
        }
        if (other.version === this.version) {
          return 0;
        }
        return this.compareMain(other) || this.comparePre(other);
      }
      compareMain(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        if (this.major < other.major) {
          return -1;
        }
        if (this.major > other.major) {
          return 1;
        }
        if (this.minor < other.minor) {
          return -1;
        }
        if (this.minor > other.minor) {
          return 1;
        }
        if (this.patch < other.patch) {
          return -1;
        }
        if (this.patch > other.patch) {
          return 1;
        }
        return 0;
      }
      comparePre(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        if (this.prerelease.length && !other.prerelease.length) {
          return -1;
        } else if (!this.prerelease.length && other.prerelease.length) {
          return 1;
        } else if (!this.prerelease.length && !other.prerelease.length) {
          return 0;
        }
        let i = 0;
        do {
          const a = this.prerelease[i];
          const b = other.prerelease[i];
          debug("prerelease compare", i, a, b);
          if (a === void 0 && b === void 0) {
            return 0;
          } else if (b === void 0) {
            return 1;
          } else if (a === void 0) {
            return -1;
          } else if (a === b) {
            continue;
          } else {
            return compareIdentifiers(a, b);
          }
        } while (++i);
      }
      compareBuild(other) {
        if (!(other instanceof _SemVer)) {
          other = new _SemVer(other, this.options);
        }
        let i = 0;
        do {
          const a = this.build[i];
          const b = other.build[i];
          debug("build compare", i, a, b);
          if (a === void 0 && b === void 0) {
            return 0;
          } else if (b === void 0) {
            return 1;
          } else if (a === void 0) {
            return -1;
          } else if (a === b) {
            continue;
          } else {
            return compareIdentifiers(a, b);
          }
        } while (++i);
      }
      // preminor will bump the version up to the next minor release, and immediately
      // down to pre-release. premajor and prepatch work the same way.
      inc(release, identifier, identifierBase) {
        if (release.startsWith("pre")) {
          if (!identifier && identifierBase === false) {
            throw new Error("invalid increment argument: identifier is empty");
          }
          if (identifier) {
            const match = `-${identifier}`.match(this.options.loose ? re[t.PRERELEASELOOSE] : re[t.PRERELEASE]);
            if (!match || match[1] !== identifier) {
              throw new Error(`invalid identifier: ${identifier}`);
            }
          }
        }
        switch (release) {
          case "premajor":
            this.prerelease.length = 0;
            this.patch = 0;
            this.minor = 0;
            this.major++;
            this.inc("pre", identifier, identifierBase);
            break;
          case "preminor":
            this.prerelease.length = 0;
            this.patch = 0;
            this.minor++;
            this.inc("pre", identifier, identifierBase);
            break;
          case "prepatch":
            this.prerelease.length = 0;
            this.inc("patch", identifier, identifierBase);
            this.inc("pre", identifier, identifierBase);
            break;
          // If the input is a non-prerelease version, this acts the same as
          // prepatch.
          case "prerelease":
            if (this.prerelease.length === 0) {
              this.inc("patch", identifier, identifierBase);
            }
            this.inc("pre", identifier, identifierBase);
            break;
          case "release":
            if (this.prerelease.length === 0) {
              throw new Error(`version ${this.raw} is not a prerelease`);
            }
            this.prerelease.length = 0;
            break;
          case "major":
            if (this.minor !== 0 || this.patch !== 0 || this.prerelease.length === 0) {
              this.major++;
            }
            this.minor = 0;
            this.patch = 0;
            this.prerelease = [];
            break;
          case "minor":
            if (this.patch !== 0 || this.prerelease.length === 0) {
              this.minor++;
            }
            this.patch = 0;
            this.prerelease = [];
            break;
          case "patch":
            if (this.prerelease.length === 0) {
              this.patch++;
            }
            this.prerelease = [];
            break;
          // This probably shouldn't be used publicly.
          // 1.0.0 'pre' would become 1.0.0-0 which is the wrong direction.
          case "pre": {
            const base = Number(identifierBase) ? 1 : 0;
            if (this.prerelease.length === 0) {
              this.prerelease = [base];
            } else {
              let i = this.prerelease.length;
              while (--i >= 0) {
                if (typeof this.prerelease[i] === "number") {
                  this.prerelease[i]++;
                  i = -2;
                }
              }
              if (i === -1) {
                if (identifier === this.prerelease.join(".") && identifierBase === false) {
                  throw new Error("invalid increment argument: identifier already exists");
                }
                this.prerelease.push(base);
              }
            }
            if (identifier) {
              let prerelease2 = [identifier, base];
              if (identifierBase === false) {
                prerelease2 = [identifier];
              }
              if (isPrereleaseIdentifier(this.prerelease, identifier)) {
                const prereleaseBase = this.prerelease[identifier.split(".").length];
                if (isNaN(prereleaseBase)) {
                  this.prerelease = prerelease2;
                }
              } else {
                this.prerelease = prerelease2;
              }
            }
            break;
          }
          default:
            throw new Error(`invalid increment argument: ${release}`);
        }
        this.raw = this.format();
        if (this.build.length) {
          this.raw += `+${this.build.join(".")}`;
        }
        return this;
      }
    };
    module.exports = SemVer;
  }
});

// node_modules/semver/functions/parse.js
var require_parse = __commonJS({
  "node_modules/semver/functions/parse.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var parse = (version, options, throwErrors = false) => {
      if (version instanceof SemVer) {
        return version;
      }
      try {
        return new SemVer(version, options);
      } catch (er) {
        if (!throwErrors) {
          return null;
        }
        throw er;
      }
    };
    module.exports = parse;
  }
});

// node_modules/semver/functions/valid.js
var require_valid = __commonJS({
  "node_modules/semver/functions/valid.js"(exports, module) {
    "use strict";
    var parse = require_parse();
    var valid2 = (version, options) => {
      const v = parse(version, options);
      return v ? v.version : null;
    };
    module.exports = valid2;
  }
});

// node_modules/semver/functions/clean.js
var require_clean = __commonJS({
  "node_modules/semver/functions/clean.js"(exports, module) {
    "use strict";
    var parse = require_parse();
    var clean = (version, options) => {
      const s = parse(version.trim().replace(/^[=v]+/, ""), options);
      return s ? s.version : null;
    };
    module.exports = clean;
  }
});

// node_modules/semver/functions/inc.js
var require_inc = __commonJS({
  "node_modules/semver/functions/inc.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var inc = (version, release, options, identifier, identifierBase) => {
      if (typeof options === "string") {
        identifierBase = identifier;
        identifier = options;
        options = void 0;
      }
      try {
        return new SemVer(
          version instanceof SemVer ? version.version : version,
          options
        ).inc(release, identifier, identifierBase).version;
      } catch (er) {
        return null;
      }
    };
    module.exports = inc;
  }
});

// node_modules/semver/functions/diff.js
var require_diff = __commonJS({
  "node_modules/semver/functions/diff.js"(exports, module) {
    "use strict";
    var parse = require_parse();
    var diff = (version1, version2) => {
      const v1 = parse(version1, null, true);
      const v2 = parse(version2, null, true);
      const comparison = v1.compare(v2);
      if (comparison === 0) {
        return null;
      }
      const v1Higher = comparison > 0;
      const highVersion = v1Higher ? v1 : v2;
      const lowVersion = v1Higher ? v2 : v1;
      const highHasPre = !!highVersion.prerelease.length;
      const lowHasPre = !!lowVersion.prerelease.length;
      if (lowHasPre && !highHasPre) {
        if (!lowVersion.patch && !lowVersion.minor) {
          return "major";
        }
        if (lowVersion.compareMain(highVersion) === 0) {
          if (lowVersion.minor && !lowVersion.patch) {
            return "minor";
          }
          return "patch";
        }
      }
      const prefix = highHasPre ? "pre" : "";
      if (v1.major !== v2.major) {
        return prefix + "major";
      }
      if (v1.minor !== v2.minor) {
        return prefix + "minor";
      }
      if (v1.patch !== v2.patch) {
        return prefix + "patch";
      }
      return "prerelease";
    };
    module.exports = diff;
  }
});

// node_modules/semver/functions/major.js
var require_major = __commonJS({
  "node_modules/semver/functions/major.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var major2 = (a, loose) => new SemVer(a, loose).major;
    module.exports = major2;
  }
});

// node_modules/semver/functions/minor.js
var require_minor = __commonJS({
  "node_modules/semver/functions/minor.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var minor = (a, loose) => new SemVer(a, loose).minor;
    module.exports = minor;
  }
});

// node_modules/semver/functions/patch.js
var require_patch = __commonJS({
  "node_modules/semver/functions/patch.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var patch = (a, loose) => new SemVer(a, loose).patch;
    module.exports = patch;
  }
});

// node_modules/semver/functions/prerelease.js
var require_prerelease = __commonJS({
  "node_modules/semver/functions/prerelease.js"(exports, module) {
    "use strict";
    var parse = require_parse();
    var prerelease2 = (version, options) => {
      const parsed = parse(version, options);
      return parsed && parsed.prerelease.length ? parsed.prerelease : null;
    };
    module.exports = prerelease2;
  }
});

// node_modules/semver/functions/compare.js
var require_compare = __commonJS({
  "node_modules/semver/functions/compare.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var compare3 = (a, b, loose) => new SemVer(a, loose).compare(new SemVer(b, loose));
    module.exports = compare3;
  }
});

// node_modules/semver/functions/rcompare.js
var require_rcompare = __commonJS({
  "node_modules/semver/functions/rcompare.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var rcompare = (a, b, loose) => compare3(b, a, loose);
    module.exports = rcompare;
  }
});

// node_modules/semver/functions/compare-loose.js
var require_compare_loose = __commonJS({
  "node_modules/semver/functions/compare-loose.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var compareLoose = (a, b) => compare3(a, b, true);
    module.exports = compareLoose;
  }
});

// node_modules/semver/functions/compare-build.js
var require_compare_build = __commonJS({
  "node_modules/semver/functions/compare-build.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var compareBuild = (a, b, loose) => {
      const versionA = new SemVer(a, loose);
      const versionB = new SemVer(b, loose);
      return versionA.compare(versionB) || versionA.compareBuild(versionB);
    };
    module.exports = compareBuild;
  }
});

// node_modules/semver/functions/sort.js
var require_sort = __commonJS({
  "node_modules/semver/functions/sort.js"(exports, module) {
    "use strict";
    var compareBuild = require_compare_build();
    var sort = (list, loose) => list.sort((a, b) => compareBuild(a, b, loose));
    module.exports = sort;
  }
});

// node_modules/semver/functions/rsort.js
var require_rsort = __commonJS({
  "node_modules/semver/functions/rsort.js"(exports, module) {
    "use strict";
    var compareBuild = require_compare_build();
    var rsort = (list, loose) => list.sort((a, b) => compareBuild(b, a, loose));
    module.exports = rsort;
  }
});

// node_modules/semver/functions/gt.js
var require_gt = __commonJS({
  "node_modules/semver/functions/gt.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var gt = (a, b, loose) => compare3(a, b, loose) > 0;
    module.exports = gt;
  }
});

// node_modules/semver/functions/lt.js
var require_lt = __commonJS({
  "node_modules/semver/functions/lt.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var lt = (a, b, loose) => compare3(a, b, loose) < 0;
    module.exports = lt;
  }
});

// node_modules/semver/functions/eq.js
var require_eq = __commonJS({
  "node_modules/semver/functions/eq.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var eq = (a, b, loose) => compare3(a, b, loose) === 0;
    module.exports = eq;
  }
});

// node_modules/semver/functions/neq.js
var require_neq = __commonJS({
  "node_modules/semver/functions/neq.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var neq = (a, b, loose) => compare3(a, b, loose) !== 0;
    module.exports = neq;
  }
});

// node_modules/semver/functions/gte.js
var require_gte = __commonJS({
  "node_modules/semver/functions/gte.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var gte = (a, b, loose) => compare3(a, b, loose) >= 0;
    module.exports = gte;
  }
});

// node_modules/semver/functions/lte.js
var require_lte = __commonJS({
  "node_modules/semver/functions/lte.js"(exports, module) {
    "use strict";
    var compare3 = require_compare();
    var lte = (a, b, loose) => compare3(a, b, loose) <= 0;
    module.exports = lte;
  }
});

// node_modules/semver/functions/cmp.js
var require_cmp = __commonJS({
  "node_modules/semver/functions/cmp.js"(exports, module) {
    "use strict";
    var eq = require_eq();
    var neq = require_neq();
    var gt = require_gt();
    var gte = require_gte();
    var lt = require_lt();
    var lte = require_lte();
    var cmp = (a, op, b, loose) => {
      switch (op) {
        case "===":
          if (typeof a === "object") {
            a = a.version;
          }
          if (typeof b === "object") {
            b = b.version;
          }
          return a === b;
        case "!==":
          if (typeof a === "object") {
            a = a.version;
          }
          if (typeof b === "object") {
            b = b.version;
          }
          return a !== b;
        case "":
        case "=":
        case "==":
          return eq(a, b, loose);
        case "!=":
          return neq(a, b, loose);
        case ">":
          return gt(a, b, loose);
        case ">=":
          return gte(a, b, loose);
        case "<":
          return lt(a, b, loose);
        case "<=":
          return lte(a, b, loose);
        default:
          throw new TypeError(`Invalid operator: ${op}`);
      }
    };
    module.exports = cmp;
  }
});

// node_modules/semver/functions/coerce.js
var require_coerce = __commonJS({
  "node_modules/semver/functions/coerce.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var parse = require_parse();
    var { safeRe: re, t } = require_re();
    var coerce = (version, options) => {
      if (version instanceof SemVer) {
        return version;
      }
      if (typeof version === "number") {
        version = String(version);
      }
      if (typeof version !== "string") {
        return null;
      }
      options = options || {};
      let match = null;
      if (!options.rtl) {
        match = version.match(options.includePrerelease ? re[t.COERCEFULL] : re[t.COERCE]);
      } else {
        const coerceRtlRegex = options.includePrerelease ? re[t.COERCERTLFULL] : re[t.COERCERTL];
        let next;
        while ((next = coerceRtlRegex.exec(version)) && (!match || match.index + match[0].length !== version.length)) {
          if (!match || next.index + next[0].length !== match.index + match[0].length) {
            match = next;
          }
          coerceRtlRegex.lastIndex = next.index + next[1].length + next[2].length;
        }
        coerceRtlRegex.lastIndex = -1;
      }
      if (match === null) {
        return null;
      }
      const major2 = match[2];
      const minor = match[3] || "0";
      const patch = match[4] || "0";
      const prerelease2 = options.includePrerelease && match[5] ? `-${match[5]}` : "";
      const build = options.includePrerelease && match[6] ? `+${match[6]}` : "";
      return parse(`${major2}.${minor}.${patch}${prerelease2}${build}`, options);
    };
    module.exports = coerce;
  }
});

// node_modules/semver/functions/truncate.js
var require_truncate = __commonJS({
  "node_modules/semver/functions/truncate.js"(exports, module) {
    "use strict";
    var parse = require_parse();
    var constants = require_constants();
    var SemVer = require_semver();
    var truncate = (version, truncation, options) => {
      if (!constants.RELEASE_TYPES.includes(truncation)) {
        return null;
      }
      const clonedVersion = cloneInputVersion(version, options);
      return clonedVersion && doTruncation(clonedVersion, truncation);
    };
    var cloneInputVersion = (version, options) => {
      const versionStringToParse = version instanceof SemVer ? version.version : version;
      return parse(versionStringToParse, options);
    };
    var doTruncation = (version, truncation) => {
      if (isPrerelease(truncation)) {
        return version.version;
      }
      version.prerelease = [];
      switch (truncation) {
        case "major":
          version.minor = 0;
          version.patch = 0;
          break;
        case "minor":
          version.patch = 0;
          break;
      }
      return version.format();
    };
    var isPrerelease = (type) => {
      return type.startsWith("pre");
    };
    module.exports = truncate;
  }
});

// node_modules/semver/internal/lrucache.js
var require_lrucache = __commonJS({
  "node_modules/semver/internal/lrucache.js"(exports, module) {
    "use strict";
    var LRUCache = class {
      constructor() {
        this.max = 1e3;
        this.map = /* @__PURE__ */ new Map();
      }
      get(key) {
        const value = this.map.get(key);
        if (value === void 0) {
          return void 0;
        } else {
          this.map.delete(key);
          this.map.set(key, value);
          return value;
        }
      }
      delete(key) {
        return this.map.delete(key);
      }
      set(key, value) {
        const deleted = this.delete(key);
        if (!deleted && value !== void 0) {
          if (this.map.size >= this.max) {
            const firstKey = this.map.keys().next().value;
            this.delete(firstKey);
          }
          this.map.set(key, value);
        }
        return this;
      }
    };
    module.exports = LRUCache;
  }
});

// node_modules/semver/classes/range.js
var require_range = __commonJS({
  "node_modules/semver/classes/range.js"(exports, module) {
    "use strict";
    var SPACE_CHARACTERS = /\s+/g;
    var Range = class _Range {
      constructor(range, options) {
        options = parseOptions(options);
        if (range instanceof _Range) {
          if (range.loose === !!options.loose && range.includePrerelease === !!options.includePrerelease) {
            return range;
          } else {
            return new _Range(range.raw, options);
          }
        }
        if (range instanceof Comparator) {
          this.raw = range.value;
          this.set = [[range]];
          this.formatted = void 0;
          return this;
        }
        this.options = options;
        this.loose = !!options.loose;
        this.includePrerelease = !!options.includePrerelease;
        this.raw = range.trim().replace(SPACE_CHARACTERS, " ");
        this.set = this.raw.split("||").map((r) => this.parseRange(r.trim())).filter((c) => c.length);
        if (!this.set.length) {
          throw new TypeError(`Invalid SemVer Range: ${this.raw}`);
        }
        if (this.set.length > 1) {
          const first = this.set[0];
          this.set = this.set.filter((c) => !isNullSet(c[0]));
          if (this.set.length === 0) {
            this.set = [first];
          } else if (this.set.length > 1) {
            for (const c of this.set) {
              if (c.length === 1 && isAny(c[0])) {
                this.set = [c];
                break;
              }
            }
          }
        }
        this.formatted = void 0;
      }
      get range() {
        if (this.formatted === void 0) {
          this.formatted = "";
          for (let i = 0; i < this.set.length; i++) {
            if (i > 0) {
              this.formatted += "||";
            }
            const comps = this.set[i];
            for (let k = 0; k < comps.length; k++) {
              if (k > 0) {
                this.formatted += " ";
              }
              this.formatted += comps[k].toString().trim();
            }
          }
        }
        return this.formatted;
      }
      format() {
        return this.range;
      }
      toString() {
        return this.range;
      }
      parseRange(range) {
        range = range.replace(BUILDSTRIPRE, "");
        const memoOpts = (this.options.includePrerelease && FLAG_INCLUDE_PRERELEASE) | (this.options.loose && FLAG_LOOSE);
        const memoKey = memoOpts + ":" + range;
        const cached = cache.get(memoKey);
        if (cached) {
          return cached;
        }
        const loose = this.options.loose;
        const hr = loose ? re[t.HYPHENRANGELOOSE] : re[t.HYPHENRANGE];
        range = range.replace(hr, hyphenReplace(this.options.includePrerelease));
        debug("hyphen replace", range);
        range = range.replace(re[t.COMPARATORTRIM], comparatorTrimReplace);
        debug("comparator trim", range);
        range = range.replace(re[t.TILDETRIM], tildeTrimReplace);
        debug("tilde trim", range);
        range = range.replace(re[t.CARETTRIM], caretTrimReplace);
        debug("caret trim", range);
        let rangeList = range.split(" ").map((comp) => parseComparator(comp, this.options)).join(" ").split(/\s+/).map((comp) => replaceGTE0(comp, this.options));
        if (loose) {
          rangeList = rangeList.filter((comp) => {
            debug("loose invalid filter", comp, this.options);
            return !!comp.match(re[t.COMPARATORLOOSE]);
          });
        }
        debug("range list", rangeList);
        const rangeMap = /* @__PURE__ */ new Map();
        const comparators = rangeList.map((comp) => new Comparator(comp, this.options));
        for (const comp of comparators) {
          if (isNullSet(comp)) {
            return [comp];
          }
          rangeMap.set(comp.value, comp);
        }
        if (rangeMap.size > 1 && rangeMap.has("")) {
          rangeMap.delete("");
        }
        const result = [...rangeMap.values()];
        cache.set(memoKey, result);
        return result;
      }
      intersects(range, options) {
        if (!(range instanceof _Range)) {
          throw new TypeError("a Range is required");
        }
        return this.set.some((thisComparators) => {
          return isSatisfiable(thisComparators, options) && range.set.some((rangeComparators) => {
            return isSatisfiable(rangeComparators, options) && thisComparators.every((thisComparator) => {
              return rangeComparators.every((rangeComparator) => {
                return thisComparator.intersects(rangeComparator, options);
              });
            });
          });
        });
      }
      // if ANY of the sets match ALL of its comparators, then pass
      test(version) {
        if (!version) {
          return false;
        }
        if (typeof version === "string") {
          try {
            version = new SemVer(version, this.options);
          } catch (er) {
            return false;
          }
        }
        for (let i = 0; i < this.set.length; i++) {
          if (testSet(this.set[i], version, this.options)) {
            return true;
          }
        }
        return false;
      }
    };
    module.exports = Range;
    var LRU = require_lrucache();
    var cache = new LRU();
    var parseOptions = require_parse_options();
    var Comparator = require_comparator();
    var debug = require_debug();
    var SemVer = require_semver();
    var {
      safeRe: re,
      src,
      t,
      comparatorTrimReplace,
      tildeTrimReplace,
      caretTrimReplace
    } = require_re();
    var { FLAG_INCLUDE_PRERELEASE, FLAG_LOOSE } = require_constants();
    var BUILDSTRIPRE = new RegExp(src[t.BUILD], "g");
    var isNullSet = (c) => c.value === "<0.0.0-0";
    var isAny = (c) => c.value === "";
    var isSatisfiable = (comparators, options) => {
      let result = true;
      const remainingComparators = comparators.slice();
      let testComparator = remainingComparators.pop();
      while (result && remainingComparators.length) {
        result = remainingComparators.every((otherComparator) => {
          return testComparator.intersects(otherComparator, options);
        });
        testComparator = remainingComparators.pop();
      }
      return result;
    };
    var parseComparator = (comp, options) => {
      comp = comp.replace(re[t.BUILD], "");
      debug("comp", comp, options);
      comp = replaceCarets(comp, options);
      debug("caret", comp);
      comp = replaceTildes(comp, options);
      debug("tildes", comp);
      comp = replaceXRanges(comp, options);
      debug("xrange", comp);
      comp = replaceStars(comp, options);
      debug("stars", comp);
      return comp;
    };
    var isX = (id) => !id || id.toLowerCase() === "x" || id === "*";
    var invalidXRangeOrder = (M, m, p) => isX(M) && !isX(m) || isX(m) && p && !isX(p);
    var replaceTildes = (comp, options) => {
      return comp.trim().split(/\s+/).map((c) => replaceTilde(c, options)).join(" ");
    };
    var replaceTilde = (comp, options) => {
      const r = options.loose ? re[t.TILDELOOSE] : re[t.TILDE];
      const z = options.includePrerelease ? "-0" : "";
      return comp.replace(r, (_, M, m, p, pr) => {
        debug("tilde", comp, _, M, m, p, pr);
        let ret;
        if (isX(M)) {
          ret = "";
        } else if (isX(m)) {
          ret = `>=${M}.0.0${z} <${+M + 1}.0.0-0`;
        } else if (isX(p)) {
          ret = `>=${M}.${m}.0${z} <${M}.${+m + 1}.0-0`;
        } else if (pr) {
          debug("replaceTilde pr", pr);
          ret = `>=${M}.${m}.${p}-${pr} <${M}.${+m + 1}.0-0`;
        } else {
          ret = `>=${M}.${m}.${p} <${M}.${+m + 1}.0-0`;
        }
        debug("tilde return", ret);
        return ret;
      });
    };
    var replaceCarets = (comp, options) => {
      return comp.trim().split(/\s+/).map((c) => replaceCaret(c, options)).join(" ");
    };
    var replaceCaret = (comp, options) => {
      debug("caret", comp, options);
      const r = options.loose ? re[t.CARETLOOSE] : re[t.CARET];
      const z = options.includePrerelease ? "-0" : "";
      return comp.replace(r, (_, M, m, p, pr) => {
        debug("caret", comp, _, M, m, p, pr);
        let ret;
        if (isX(M)) {
          ret = "";
        } else if (isX(m)) {
          ret = `>=${M}.0.0${z} <${+M + 1}.0.0-0`;
        } else if (isX(p)) {
          if (M === "0") {
            ret = `>=${M}.${m}.0${z} <${M}.${+m + 1}.0-0`;
          } else {
            ret = `>=${M}.${m}.0${z} <${+M + 1}.0.0-0`;
          }
        } else if (pr) {
          debug("replaceCaret pr", pr);
          if (M === "0") {
            if (m === "0") {
              ret = `>=${M}.${m}.${p}-${pr} <${M}.${m}.${+p + 1}-0`;
            } else {
              ret = `>=${M}.${m}.${p}-${pr} <${M}.${+m + 1}.0-0`;
            }
          } else {
            ret = `>=${M}.${m}.${p}-${pr} <${+M + 1}.0.0-0`;
          }
        } else {
          debug("no pr");
          if (M === "0") {
            if (m === "0") {
              ret = `>=${M}.${m}.${p} <${M}.${m}.${+p + 1}-0`;
            } else {
              ret = `>=${M}.${m}.${p} <${M}.${+m + 1}.0-0`;
            }
          } else {
            ret = `>=${M}.${m}.${p} <${+M + 1}.0.0-0`;
          }
        }
        debug("caret return", ret);
        return ret;
      });
    };
    var replaceXRanges = (comp, options) => {
      debug("replaceXRanges", comp, options);
      return comp.split(/\s+/).map((c) => replaceXRange(c, options)).join(" ");
    };
    var replaceXRange = (comp, options) => {
      comp = comp.trim();
      const r = options.loose ? re[t.XRANGELOOSE] : re[t.XRANGE];
      return comp.replace(r, (ret, gtlt, M, m, p, pr) => {
        debug("xRange", comp, ret, gtlt, M, m, p, pr);
        if (invalidXRangeOrder(M, m, p)) {
          return comp;
        }
        const xM = isX(M);
        const xm = xM || isX(m);
        const xp = xm || isX(p);
        const anyX = xp;
        if (gtlt === "=" && anyX) {
          gtlt = "";
        }
        pr = options.includePrerelease ? "-0" : "";
        if (xM) {
          if (gtlt === ">" || gtlt === "<") {
            ret = "<0.0.0-0";
          } else {
            ret = "*";
          }
        } else if (gtlt && anyX) {
          if (xm) {
            m = 0;
          }
          p = 0;
          if (gtlt === ">") {
            gtlt = ">=";
            if (xm) {
              M = +M + 1;
              m = 0;
              p = 0;
            } else {
              m = +m + 1;
              p = 0;
            }
          } else if (gtlt === "<=") {
            gtlt = "<";
            if (xm) {
              M = +M + 1;
            } else {
              m = +m + 1;
            }
          }
          if (gtlt === "<") {
            pr = "-0";
          }
          ret = `${gtlt + M}.${m}.${p}${pr}`;
        } else if (xm) {
          ret = `>=${M}.0.0${pr} <${+M + 1}.0.0-0`;
        } else if (xp) {
          ret = `>=${M}.${m}.0${pr} <${M}.${+m + 1}.0-0`;
        }
        debug("xRange return", ret);
        return ret;
      });
    };
    var replaceStars = (comp, options) => {
      debug("replaceStars", comp, options);
      return comp.trim().replace(re[t.STAR], "");
    };
    var replaceGTE0 = (comp, options) => {
      debug("replaceGTE0", comp, options);
      return comp.trim().replace(re[options.includePrerelease ? t.GTE0PRE : t.GTE0], "");
    };
    var hyphenReplace = (incPr) => ($0, from, fM, fm, fp, fpr, fb, to, tM, tm, tp, tpr) => {
      if (isX(fM)) {
        from = "";
      } else if (isX(fm)) {
        from = `>=${fM}.0.0${incPr ? "-0" : ""}`;
      } else if (isX(fp)) {
        from = `>=${fM}.${fm}.0${incPr ? "-0" : ""}`;
      } else if (fpr) {
        from = `>=${from}`;
      } else {
        from = `>=${from}${incPr ? "-0" : ""}`;
      }
      if (isX(tM)) {
        to = "";
      } else if (isX(tm)) {
        to = `<${+tM + 1}.0.0-0`;
      } else if (isX(tp)) {
        to = `<${tM}.${+tm + 1}.0-0`;
      } else if (tpr) {
        to = `<=${tM}.${tm}.${tp}-${tpr}`;
      } else if (incPr) {
        to = `<${tM}.${tm}.${+tp + 1}-0`;
      } else {
        to = `<=${to}`;
      }
      return `${from} ${to}`.trim();
    };
    var testSet = (set, version, options) => {
      for (let i = 0; i < set.length; i++) {
        if (!set[i].test(version)) {
          return false;
        }
      }
      if (version.prerelease.length && !options.includePrerelease) {
        for (let i = 0; i < set.length; i++) {
          debug(set[i].semver);
          if (set[i].semver === Comparator.ANY) {
            continue;
          }
          if (set[i].semver.prerelease.length > 0) {
            const allowed = set[i].semver;
            if (allowed.major === version.major && allowed.minor === version.minor && allowed.patch === version.patch) {
              return true;
            }
          }
        }
        return false;
      }
      return true;
    };
  }
});

// node_modules/semver/classes/comparator.js
var require_comparator = __commonJS({
  "node_modules/semver/classes/comparator.js"(exports, module) {
    "use strict";
    var ANY = /* @__PURE__ */ Symbol("SemVer ANY");
    var Comparator = class _Comparator {
      static get ANY() {
        return ANY;
      }
      constructor(comp, options) {
        options = parseOptions(options);
        if (comp instanceof _Comparator) {
          if (comp.loose === !!options.loose) {
            return comp;
          } else {
            comp = comp.value;
          }
        }
        comp = comp.trim().split(/\s+/).join(" ");
        debug("comparator", comp, options);
        this.options = options;
        this.loose = !!options.loose;
        this.parse(comp);
        if (this.semver === ANY) {
          this.value = "";
        } else {
          this.value = this.operator + this.semver.version;
        }
        debug("comp", this);
      }
      parse(comp) {
        const r = this.options.loose ? re[t.COMPARATORLOOSE] : re[t.COMPARATOR];
        const m = comp.match(r);
        if (!m) {
          throw new TypeError(`Invalid comparator: ${comp}`);
        }
        this.operator = m[1] !== void 0 ? m[1] : "";
        if (this.operator === "=") {
          this.operator = "";
        }
        if (!m[2]) {
          this.semver = ANY;
        } else {
          this.semver = new SemVer(m[2], this.options.loose);
        }
      }
      toString() {
        return this.value;
      }
      test(version) {
        debug("Comparator.test", version, this.options.loose);
        if (this.semver === ANY || version === ANY) {
          return true;
        }
        if (typeof version === "string") {
          try {
            version = new SemVer(version, this.options);
          } catch (er) {
            return false;
          }
        }
        return cmp(version, this.operator, this.semver, this.options);
      }
      intersects(comp, options) {
        if (!(comp instanceof _Comparator)) {
          throw new TypeError("a Comparator is required");
        }
        if (this.operator === "") {
          if (this.value === "") {
            return true;
          }
          return new Range(comp.value, options).test(this.value);
        } else if (comp.operator === "") {
          if (comp.value === "") {
            return true;
          }
          return new Range(this.value, options).test(comp.semver);
        }
        options = parseOptions(options);
        if (options.includePrerelease && (this.value === "<0.0.0-0" || comp.value === "<0.0.0-0")) {
          return false;
        }
        if (!options.includePrerelease && (this.value.startsWith("<0.0.0") || comp.value.startsWith("<0.0.0"))) {
          return false;
        }
        if (this.operator.startsWith(">") && comp.operator.startsWith(">")) {
          return true;
        }
        if (this.operator.startsWith("<") && comp.operator.startsWith("<")) {
          return true;
        }
        if (this.semver.version === comp.semver.version && this.operator.includes("=") && comp.operator.includes("=")) {
          return true;
        }
        if (cmp(this.semver, "<", comp.semver, options) && this.operator.startsWith(">") && comp.operator.startsWith("<")) {
          return true;
        }
        if (cmp(this.semver, ">", comp.semver, options) && this.operator.startsWith("<") && comp.operator.startsWith(">")) {
          return true;
        }
        return false;
      }
    };
    module.exports = Comparator;
    var parseOptions = require_parse_options();
    var { safeRe: re, t } = require_re();
    var cmp = require_cmp();
    var debug = require_debug();
    var SemVer = require_semver();
    var Range = require_range();
  }
});

// node_modules/semver/functions/satisfies.js
var require_satisfies = __commonJS({
  "node_modules/semver/functions/satisfies.js"(exports, module) {
    "use strict";
    var Range = require_range();
    var satisfies2 = (version, range, options) => {
      try {
        range = new Range(range, options);
      } catch (er) {
        return false;
      }
      return range.test(version);
    };
    module.exports = satisfies2;
  }
});

// node_modules/semver/ranges/to-comparators.js
var require_to_comparators = __commonJS({
  "node_modules/semver/ranges/to-comparators.js"(exports, module) {
    "use strict";
    var Range = require_range();
    var toComparators = (range, options) => new Range(range, options).set.map((comp) => comp.map((c) => c.value).join(" ").trim().split(" "));
    module.exports = toComparators;
  }
});

// node_modules/semver/ranges/max-satisfying.js
var require_max_satisfying = __commonJS({
  "node_modules/semver/ranges/max-satisfying.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var Range = require_range();
    var maxSatisfying2 = (versions, range, options) => {
      let max = null;
      let maxSV = null;
      let rangeObj = null;
      try {
        rangeObj = new Range(range, options);
      } catch (er) {
        return null;
      }
      versions.forEach((v) => {
        if (rangeObj.test(v)) {
          if (!max || maxSV.compare(v) === -1) {
            max = v;
            maxSV = new SemVer(max, options);
          }
        }
      });
      return max;
    };
    module.exports = maxSatisfying2;
  }
});

// node_modules/semver/ranges/min-satisfying.js
var require_min_satisfying = __commonJS({
  "node_modules/semver/ranges/min-satisfying.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var Range = require_range();
    var minSatisfying = (versions, range, options) => {
      let min = null;
      let minSV = null;
      let rangeObj = null;
      try {
        rangeObj = new Range(range, options);
      } catch (er) {
        return null;
      }
      versions.forEach((v) => {
        if (rangeObj.test(v)) {
          if (!min || minSV.compare(v) === 1) {
            min = v;
            minSV = new SemVer(min, options);
          }
        }
      });
      return min;
    };
    module.exports = minSatisfying;
  }
});

// node_modules/semver/ranges/min-version.js
var require_min_version = __commonJS({
  "node_modules/semver/ranges/min-version.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var Range = require_range();
    var gt = require_gt();
    var minVersion = (range, loose) => {
      range = new Range(range, loose);
      let minver = new SemVer("0.0.0");
      if (range.test(minver)) {
        return minver;
      }
      minver = new SemVer("0.0.0-0");
      if (range.test(minver)) {
        return minver;
      }
      minver = null;
      for (let i = 0; i < range.set.length; ++i) {
        const comparators = range.set[i];
        let setMin = null;
        comparators.forEach((comparator) => {
          const compver = new SemVer(comparator.semver.version);
          switch (comparator.operator) {
            case ">":
              if (compver.prerelease.length === 0) {
                compver.patch++;
              } else {
                compver.prerelease.push(0);
              }
              compver.raw = compver.format();
            /* fallthrough */
            case "":
            case ">=":
              if (!setMin || gt(compver, setMin)) {
                setMin = compver;
              }
              break;
            case "<":
            case "<=":
              break;
            /* istanbul ignore next */
            default:
              throw new Error(`Unexpected operation: ${comparator.operator}`);
          }
        });
        if (setMin && (!minver || gt(minver, setMin))) {
          minver = setMin;
        }
      }
      if (minver && range.test(minver)) {
        return minver;
      }
      return null;
    };
    module.exports = minVersion;
  }
});

// node_modules/semver/ranges/valid.js
var require_valid2 = __commonJS({
  "node_modules/semver/ranges/valid.js"(exports, module) {
    "use strict";
    var Range = require_range();
    var validRange2 = (range, options) => {
      try {
        return new Range(range, options).range || "*";
      } catch (er) {
        return null;
      }
    };
    module.exports = validRange2;
  }
});

// node_modules/semver/ranges/outside.js
var require_outside = __commonJS({
  "node_modules/semver/ranges/outside.js"(exports, module) {
    "use strict";
    var SemVer = require_semver();
    var Comparator = require_comparator();
    var { ANY } = Comparator;
    var Range = require_range();
    var satisfies2 = require_satisfies();
    var gt = require_gt();
    var lt = require_lt();
    var lte = require_lte();
    var gte = require_gte();
    var outside = (version, range, hilo, options) => {
      version = new SemVer(version, options);
      range = new Range(range, options);
      let gtfn, ltefn, ltfn, comp, ecomp;
      switch (hilo) {
        case ">":
          gtfn = gt;
          ltefn = lte;
          ltfn = lt;
          comp = ">";
          ecomp = ">=";
          break;
        case "<":
          gtfn = lt;
          ltefn = gte;
          ltfn = gt;
          comp = "<";
          ecomp = "<=";
          break;
        default:
          throw new TypeError('Must provide a hilo val of "<" or ">"');
      }
      if (satisfies2(version, range, options)) {
        return false;
      }
      for (let i = 0; i < range.set.length; ++i) {
        const comparators = range.set[i];
        let high = null;
        let low = null;
        comparators.forEach((comparator) => {
          if (comparator.semver === ANY) {
            comparator = new Comparator(">=0.0.0");
          }
          high = high || comparator;
          low = low || comparator;
          if (gtfn(comparator.semver, high.semver, options)) {
            high = comparator;
          } else if (ltfn(comparator.semver, low.semver, options)) {
            low = comparator;
          }
        });
        if (high.operator === comp || high.operator === ecomp) {
          return false;
        }
        if ((!low.operator || low.operator === comp) && ltefn(version, low.semver)) {
          return false;
        } else if (low.operator === ecomp && ltfn(version, low.semver)) {
          return false;
        }
      }
      return true;
    };
    module.exports = outside;
  }
});

// node_modules/semver/ranges/gtr.js
var require_gtr = __commonJS({
  "node_modules/semver/ranges/gtr.js"(exports, module) {
    "use strict";
    var outside = require_outside();
    var gtr = (version, range, options) => outside(version, range, ">", options);
    module.exports = gtr;
  }
});

// node_modules/semver/ranges/ltr.js
var require_ltr = __commonJS({
  "node_modules/semver/ranges/ltr.js"(exports, module) {
    "use strict";
    var outside = require_outside();
    var ltr = (version, range, options) => outside(version, range, "<", options);
    module.exports = ltr;
  }
});

// node_modules/semver/ranges/intersects.js
var require_intersects = __commonJS({
  "node_modules/semver/ranges/intersects.js"(exports, module) {
    "use strict";
    var Range = require_range();
    var intersects = (r1, r2, options) => {
      r1 = new Range(r1, options);
      r2 = new Range(r2, options);
      return r1.intersects(r2, options);
    };
    module.exports = intersects;
  }
});

// node_modules/semver/ranges/simplify.js
var require_simplify = __commonJS({
  "node_modules/semver/ranges/simplify.js"(exports, module) {
    "use strict";
    var satisfies2 = require_satisfies();
    var compare3 = require_compare();
    module.exports = (versions, range, options) => {
      const set = [];
      let first = null;
      let prev = null;
      const v = versions.sort((a, b) => compare3(a, b, options));
      for (const version of v) {
        const included = satisfies2(version, range, options);
        if (included) {
          prev = version;
          if (!first) {
            first = version;
          }
        } else {
          if (prev) {
            set.push([first, prev]);
          }
          prev = null;
          first = null;
        }
      }
      if (first) {
        set.push([first, null]);
      }
      const ranges = [];
      for (const [min, max] of set) {
        if (min === max) {
          ranges.push(min);
        } else if (!max && min === v[0]) {
          ranges.push("*");
        } else if (!max) {
          ranges.push(`>=${min}`);
        } else if (min === v[0]) {
          ranges.push(`<=${max}`);
        } else {
          ranges.push(`${min} - ${max}`);
        }
      }
      const simplified = ranges.join(" || ");
      const original = typeof range.raw === "string" ? range.raw : String(range);
      return simplified.length < original.length ? simplified : range;
    };
  }
});

// node_modules/semver/ranges/subset.js
var require_subset = __commonJS({
  "node_modules/semver/ranges/subset.js"(exports, module) {
    "use strict";
    var Range = require_range();
    var Comparator = require_comparator();
    var { ANY } = Comparator;
    var satisfies2 = require_satisfies();
    var compare3 = require_compare();
    var subset = (sub, dom, options = {}) => {
      if (sub === dom) {
        return true;
      }
      sub = new Range(sub, options);
      dom = new Range(dom, options);
      let sawNonNull = false;
      OUTER: for (const simpleSub of sub.set) {
        for (const simpleDom of dom.set) {
          const isSub = simpleSubset(simpleSub, simpleDom, options);
          sawNonNull = sawNonNull || isSub !== null;
          if (isSub) {
            continue OUTER;
          }
        }
        if (sawNonNull) {
          return false;
        }
      }
      return true;
    };
    var minimumVersionWithPreRelease = [new Comparator(">=0.0.0-0")];
    var minimumVersion = [new Comparator(">=0.0.0")];
    var simpleSubset = (sub, dom, options) => {
      if (sub === dom) {
        return true;
      }
      if (sub.length === 1 && sub[0].semver === ANY) {
        if (dom.length === 1 && dom[0].semver === ANY) {
          return true;
        } else if (options.includePrerelease) {
          sub = minimumVersionWithPreRelease;
        } else {
          sub = minimumVersion;
        }
      }
      if (dom.length === 1 && dom[0].semver === ANY) {
        if (options.includePrerelease) {
          return true;
        } else {
          dom = minimumVersion;
        }
      }
      const eqSet = /* @__PURE__ */ new Set();
      let gt, lt;
      for (const c of sub) {
        if (c.operator === ">" || c.operator === ">=") {
          gt = higherGT(gt, c, options);
        } else if (c.operator === "<" || c.operator === "<=") {
          lt = lowerLT(lt, c, options);
        } else {
          eqSet.add(c.semver);
        }
      }
      if (eqSet.size > 1) {
        return null;
      }
      let gtltComp;
      if (gt && lt) {
        gtltComp = compare3(gt.semver, lt.semver, options);
        if (gtltComp > 0) {
          return null;
        } else if (gtltComp === 0 && (gt.operator !== ">=" || lt.operator !== "<=")) {
          return null;
        }
      }
      for (const eq of eqSet) {
        if (gt && !satisfies2(eq, String(gt), options)) {
          return null;
        }
        if (lt && !satisfies2(eq, String(lt), options)) {
          return null;
        }
        for (const c of dom) {
          if (!satisfies2(eq, String(c), options)) {
            return false;
          }
        }
        return true;
      }
      let higher, lower;
      let hasDomLT, hasDomGT;
      let needDomLTPre = lt && !options.includePrerelease && lt.semver.prerelease.length ? lt.semver : false;
      let needDomGTPre = gt && !options.includePrerelease && gt.semver.prerelease.length ? gt.semver : false;
      if (needDomLTPre && needDomLTPre.prerelease.length === 1 && lt.operator === "<" && needDomLTPre.prerelease[0] === 0) {
        needDomLTPre = false;
      }
      for (const c of dom) {
        hasDomGT = hasDomGT || c.operator === ">" || c.operator === ">=";
        hasDomLT = hasDomLT || c.operator === "<" || c.operator === "<=";
        if (gt) {
          if (needDomGTPre) {
            if (c.semver.prerelease && c.semver.prerelease.length && c.semver.major === needDomGTPre.major && c.semver.minor === needDomGTPre.minor && c.semver.patch === needDomGTPre.patch) {
              needDomGTPre = false;
            }
          }
          if (c.operator === ">" || c.operator === ">=") {
            higher = higherGT(gt, c, options);
            if (higher === c && higher !== gt) {
              return false;
            }
          } else if (gt.operator === ">=" && !c.test(gt.semver)) {
            return false;
          }
        }
        if (lt) {
          if (needDomLTPre) {
            if (c.semver.prerelease && c.semver.prerelease.length && c.semver.major === needDomLTPre.major && c.semver.minor === needDomLTPre.minor && c.semver.patch === needDomLTPre.patch) {
              needDomLTPre = false;
            }
          }
          if (c.operator === "<" || c.operator === "<=") {
            lower = lowerLT(lt, c, options);
            if (lower === c && lower !== lt) {
              return false;
            }
          } else if (lt.operator === "<=" && !c.test(lt.semver)) {
            return false;
          }
        }
        if (!c.operator && (lt || gt) && gtltComp !== 0) {
          return false;
        }
      }
      if (gt && hasDomLT && !lt && gtltComp !== 0) {
        return false;
      }
      if (lt && hasDomGT && !gt && gtltComp !== 0) {
        return false;
      }
      if (needDomGTPre || needDomLTPre) {
        return false;
      }
      return true;
    };
    var higherGT = (a, b, options) => {
      if (!a) {
        return b;
      }
      const comp = compare3(a.semver, b.semver, options);
      return comp > 0 ? a : comp < 0 ? b : b.operator === ">" && a.operator === ">=" ? b : a;
    };
    var lowerLT = (a, b, options) => {
      if (!a) {
        return b;
      }
      const comp = compare3(a.semver, b.semver, options);
      return comp < 0 ? a : comp > 0 ? b : b.operator === "<" && a.operator === "<=" ? b : a;
    };
    module.exports = subset;
  }
});

// node_modules/semver/index.js
var require_semver2 = __commonJS({
  "node_modules/semver/index.js"(exports, module) {
    "use strict";
    var internalRe = require_re();
    var constants = require_constants();
    var SemVer = require_semver();
    var identifiers = require_identifiers();
    var parse = require_parse();
    var valid2 = require_valid();
    var clean = require_clean();
    var inc = require_inc();
    var diff = require_diff();
    var major2 = require_major();
    var minor = require_minor();
    var patch = require_patch();
    var prerelease2 = require_prerelease();
    var compare3 = require_compare();
    var rcompare = require_rcompare();
    var compareLoose = require_compare_loose();
    var compareBuild = require_compare_build();
    var sort = require_sort();
    var rsort = require_rsort();
    var gt = require_gt();
    var lt = require_lt();
    var eq = require_eq();
    var neq = require_neq();
    var gte = require_gte();
    var lte = require_lte();
    var cmp = require_cmp();
    var coerce = require_coerce();
    var truncate = require_truncate();
    var Comparator = require_comparator();
    var Range = require_range();
    var satisfies2 = require_satisfies();
    var toComparators = require_to_comparators();
    var maxSatisfying2 = require_max_satisfying();
    var minSatisfying = require_min_satisfying();
    var minVersion = require_min_version();
    var validRange2 = require_valid2();
    var outside = require_outside();
    var gtr = require_gtr();
    var ltr = require_ltr();
    var intersects = require_intersects();
    var simplifyRange = require_simplify();
    var subset = require_subset();
    module.exports = {
      parse,
      valid: valid2,
      clean,
      inc,
      diff,
      major: major2,
      minor,
      patch,
      prerelease: prerelease2,
      compare: compare3,
      rcompare,
      compareLoose,
      compareBuild,
      sort,
      rsort,
      gt,
      lt,
      eq,
      neq,
      gte,
      lte,
      cmp,
      coerce,
      truncate,
      Comparator,
      Range,
      satisfies: satisfies2,
      toComparators,
      maxSatisfying: maxSatisfying2,
      minSatisfying,
      minVersion,
      validRange: validRange2,
      outside,
      gtr,
      ltr,
      intersects,
      simplifyRange,
      subset,
      SemVer,
      re: internalRe.re,
      src: internalRe.src,
      tokens: internalRe.t,
      SEMVER_SPEC_VERSION: constants.SEMVER_SPEC_VERSION,
      RELEASE_TYPES: constants.RELEASE_TYPES,
      compareIdentifiers: identifiers.compareIdentifiers,
      rcompareIdentifiers: identifiers.rcompareIdentifiers
    };
  }
});

// entrypoints/main.ts
import path6 from "node:path";
import { fileURLToPath } from "node:url";

// domain/domain-error.ts
var DomainError = class extends Error {
  constructor(code, category, message) {
    super(message);
    this.code = code;
    this.category = category;
    this.name = "DomainError";
  }
  code;
  category;
};

// domain/identity.ts
function createAngularMajor(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new DomainError(
      "invalid_angular_major",
      "invalid-input",
      "Angular major must be a positive safe integer."
    );
  }
  return value;
}
function createProjectId(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new DomainError(
      "invalid_project_id",
      "invalid-identity",
      "Project identity must be a non-empty string."
    );
  }
  return value;
}
function createRunId(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new DomainError(
      "invalid_run_id",
      "invalid-identity",
      "Run identity must be a non-empty string."
    );
  }
  return value;
}

// domain/angular-transition.ts
function createAngularTransition(sourceMajor, targetMajor) {
  const validatedSourceMajor = createAngularMajor(sourceMajor);
  const validatedTargetMajor = createAngularMajor(targetMajor);
  if (validatedTargetMajor !== validatedSourceMajor + 1) {
    throw new DomainError(
      "non_sequential_angular_major",
      "policy-violation",
      "Target major must be exactly one greater than source major."
    );
  }
  return {
    sourceMajor: validatedSourceMajor,
    targetMajor: validatedTargetMajor
  };
}

// domain/run-state.ts
var RUN_STATE_SCHEMA_VERSION = 1;
function createInitialRunState(input) {
  const transition = createAngularTransition(
    input.sourceMajor,
    input.targetMajor
  );
  return {
    schemaVersion: RUN_STATE_SCHEMA_VERSION,
    runId: createRunId(input.runId),
    projectId: createProjectId(input.projectId),
    ...transition,
    status: "running",
    stage: "baseline",
    revision: 0
  };
}
function decideRunTransition(state, next, evidence = "none") {
  if (!isValidRunState(state)) {
    return rejected(
      "invalid_run_state",
      "invalid-state",
      "Run schema, status, and stage must form a valid state."
    );
  }
  if (!Number.isSafeInteger(state.revision) || state.revision < 0 || state.revision === Number.MAX_SAFE_INTEGER) {
    return rejected(
      "invalid_run_revision",
      "invalid-state",
      "Run revision must be a non-negative safe integer."
    );
  }
  try {
    createAngularTransition(state.sourceMajor, state.targetMajor);
  } catch (error) {
    if (error instanceof DomainError) return { outcome: "rejected", error };
    throw error;
  }
  const sameStage = state.stage === next.stage;
  const allowed = () => ({
    outcome: "allowed",
    value: { ...state, ...next, revision: state.revision + 1 }
  });
  if (state.status === "running" && next.status === "running" && NEXT_STAGE[state.stage] === next.stage && evidence === "none") {
    return allowed();
  }
  if (state.status === "running" && next.status === "needs-repair" && sameStage && REPAIRABLE_STAGES.has(state.stage) && evidence === "none") {
    return allowed();
  }
  if (state.status === "running" && ["blocked", "failed"].includes(next.status) && sameStage && evidence === "none") {
    return allowed();
  }
  if (state.status === "needs-repair" && next.status === "running" && sameStage) {
    return evidence === "repair-verified" ? allowed() : requiresAction(
      "repair_verification_required",
      "Repair must pass its verification gate before the run resumes."
    );
  }
  if (state.status === "blocked" && next.status === "running" && sameStage) {
    return evidence === "human-confirmed-retry" ? allowed() : requiresAction(
      "retry_confirmation_required",
      "A blocked run requires explicit human confirmation before retry."
    );
  }
  if (state.status === "running" && state.stage === "validate" && next.status === "verified" && next.stage === "document" && evidence === "none") {
    return allowed();
  }
  if (state.status === "verified" && state.stage === "document" && next.status === "completed" && next.stage === "done") {
    return evidence === "documentation-completed" ? allowed() : requiresAction(
      "documentation_completion_required",
      "The run can complete only after documentation is recorded as complete."
    );
  }
  return rejected(
    "invalid_run_transition",
    "invalid-state",
    "The requested run state transition is not allowed."
  );
}
var NEXT_STAGE = {
  baseline: "resolve",
  resolve: "update-angular",
  "update-angular": "update-dependencies",
  "update-dependencies": "install",
  install: "validate"
};
var REPAIRABLE_STAGES = /* @__PURE__ */ new Set(["update-angular", "validate"]);
var RUNNING_STAGES = /* @__PURE__ */ new Set([
  "baseline",
  "resolve",
  "update-angular",
  "update-dependencies",
  "install",
  "validate"
]);
function isValidRunState(state) {
  if (state.schemaVersion !== RUN_STATE_SCHEMA_VERSION) return false;
  switch (state.status) {
    case "running":
      return RUNNING_STAGES.has(state.stage);
    case "needs-repair":
      return REPAIRABLE_STAGES.has(state.stage);
    case "verified":
      return state.stage === "document";
    case "completed":
      return state.stage === "done";
    case "blocked":
    case "failed":
      return state.stage !== "done";
  }
}
function rejected(code, category, message) {
  return {
    outcome: "rejected",
    error: new DomainError(code, category, message)
  };
}
function requiresAction(code, message) {
  return {
    outcome: "requires-human-action",
    error: new DomainError(code, "human-action-required", message)
  };
}

// application/application-error.ts
var ApplicationError = class extends Error {
  constructor(code, message, outcome = "failed") {
    super(message);
    this.code = code;
    this.outcome = outcome;
    this.name = "ApplicationError";
  }
  code;
  outcome;
};

// domain/semver-constraints.ts
var import_semver = __toESM(require_semver2(), 1);
function parseExactSemverVersion(value) {
  if (typeof value !== "string") return null;
  const version = (0, import_semver.valid)(value);
  if (version === null) return null;
  return { version, major: (0, import_semver.major)(version) };
}
function isValidSemverRange(value) {
  return typeof value === "string" && value.trim().length > 0 && (0, import_semver.validRange)(value) !== null;
}
function satisfiesAllSemverRanges(version, ranges) {
  const parsedVersion = parseExactSemverVersion(version);
  if (parsedVersion === null) return false;
  return ranges.every((range) => {
    if (typeof range !== "string") return false;
    const normalizedRange = (0, import_semver.validRange)(range);
    return normalizedRange !== null && (0, import_semver.satisfies)(parsedVersion.version, normalizedRange);
  });
}
function selectHighestSatisfyingSemverVersion(versions, ranges) {
  if (versions.some((version) => typeof version !== "string") || ranges.length === 0 || ranges.some((range) => !isValidSemverRange(range))) {
    return null;
  }
  const candidates = versions.filter(
    (version) => parseExactSemverVersion(version) !== null
  );
  const combinedRange = ranges.join(" ");
  if (!isValidSemverRange(combinedRange)) return null;
  return (0, import_semver.maxSatisfying)(candidates, combinedRange);
}

// domain/runtime-planner.ts
var import_semver2 = __toESM(require_semver2(), 1);
function planRuntime(input) {
  if (!input || !Array.isArray(input.nodeRanges) || !Array.isArray(input.candidates) || !isValidSemverRange(input.npmRange) || input.nodeRanges.some((range) => !isValidSemverRange(range))) {
    return blocked("invalid-runtime-constraints");
  }
  const candidates = /* @__PURE__ */ new Map();
  for (const candidate of input.candidates) {
    if (!candidate || candidate.status !== "installed" && candidate.status !== "missing") {
      continue;
    }
    const node = parseExactSemverVersion(candidate.nodeVersion);
    const npm = candidate.status === "installed" && candidate.npmVersion !== null ? parseExactSemverVersion(candidate.npmVersion) : null;
    if (node === null || candidate.status === "installed" && npm === null || candidate.status === "missing" && candidate.npmVersion !== null) {
      continue;
    }
    const normalized = {
      nodeVersion: node.version,
      npmVersion: npm?.version ?? null,
      status: candidate.status
    };
    const previous = candidates.get(node.version);
    if (!previous || normalized.status === "installed") {
      candidates.set(node.version, normalized);
    }
  }
  const ordered = [...candidates.values()].sort(
    (left, right) => (0, import_semver2.compare)(right.nodeVersion, left.nodeVersion)
  );
  const installed = ordered.find(
    (candidate) => candidate.status === "installed" && satisfiesAllSemverRanges(candidate.nodeVersion, input.nodeRanges) && candidate.npmVersion !== null && satisfiesAllSemverRanges(candidate.npmVersion, [input.npmRange])
  );
  if (installed) return { status: "ready", selected: installed, reason: null };
  const missing = ordered.find(
    (candidate) => candidate.status === "missing" && satisfiesAllSemverRanges(candidate.nodeVersion, input.nodeRanges)
  );
  if (missing) {
    return {
      status: "runtime-install-required",
      selected: missing,
      reason: "exact-runtime-missing"
    };
  }
  return blocked("no-compatible-runtime");
}
function blocked(reason) {
  return { status: "blocked", selected: null, reason };
}

// application/discover-project.ts
async function discoverProject(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0) {
    throw new ApplicationError(
      "project_root_invalid",
      "A project root is required for discovery."
    );
  }
  const rawInputs = await ports.reader.read(
    request.projectRoot,
    request.targetMajor
  );
  const inputs = validateInputs(rawInputs);
  const transition = createAngularTransition(
    inputs.sourceMajor,
    createAngularMajor(request.targetMajor)
  );
  const blockers = collectBlockers(inputs, transition.targetMajor);
  const nodeRanges = [
    ...inputs.nodeRanges,
    ...inputs.packages.flatMap(
      (item) => item.nodeRange ? [item.nodeRange] : []
    )
  ];
  const npmRanges = [
    inputs.npmRange,
    inputs.lockfileVersion === 1 ? ">=5" : ">=7"
  ];
  const runtimePlan = planRuntime({
    nodeRanges,
    npmRange: npmRanges.join(" "),
    candidates: inputs.runtimeCandidates
  });
  if (runtimePlan.status === "blocked") {
    blockers.push({
      code: "runtime_version_unavailable",
      message: "No exact fnm runtime satisfies the discovered Node and npm constraints."
    });
  }
  const status = blockers.length > 0 ? "blocked" : runtimePlan.status === "runtime-install-required" ? "runtime-install-required" : "ready";
  const content = {
    schemaVersion: 1,
    projectId: inputs.projectId,
    inputFingerprint: inputs.inputFingerprint,
    sourceMajor: transition.sourceMajor,
    targetMajor: transition.targetMajor,
    status,
    lockfileVersion: inputs.lockfileVersion,
    checks: [...inputs.checks].sort(
      (left, right) => left.id.localeCompare(right.id)
    ),
    packages: [...inputs.packages].sort(
      (left, right) => left.name.localeCompare(right.name)
    ),
    registryIdentities: [...inputs.registryIdentities].sort(
      (left, right) => left.scope.localeCompare(right.scope)
    ),
    runtimePlan: {
      ...runtimePlan,
      nodeRanges: [...new Set(nodeRanges)].sort(),
      npmRange: npmRanges.join(" "),
      metadataNodeVersion: inputs.metadataRuntimeVersion,
      operations: [
        "npm ci",
        "npm ls --all",
        "npm exec -- ng update",
        "npm install --package-lock-only --ignore-scripts",
        ...inputs.checks.filter((check) => check.status === "configured").map((check) => `${check.executable} ${check.arguments.join(" ")}`)
      ].sort()
    },
    blockers: blockers.sort(
      (left, right) => left.code.localeCompare(right.code)
    )
  };
  const planHash = await ports.hasher.hash(content);
  if (!isSha256(planHash)) {
    throw new ApplicationError(
      "discovery_hash_invalid",
      "The discovery plan could not be integrity-bound."
    );
  }
  const record = { ...content, planHash };
  await ports.records.write(request.projectRoot, record);
  return record;
}
async function readValidatedDiscoveryRecord(value, expected, hasher) {
  if (!isDiscoveryRecord(value)) {
    throw new ApplicationError(
      "discovery_invalid",
      "The persisted discovery record is invalid."
    );
  }
  const { planHash, ...content } = value;
  if (await hasher.hash(content) !== planHash) {
    throw new ApplicationError(
      "discovery_integrity_failed",
      "The persisted discovery record has been altered."
    );
  }
  if (value.projectId !== expected.projectId || value.targetMajor !== expected.targetMajor) {
    throw new ApplicationError(
      "discovery_context_mismatch",
      "The discovery record does not describe the requested project or target."
    );
  }
  if (value.inputFingerprint !== expected.inputFingerprint) {
    throw new ApplicationError(
      "discovery_stale",
      "Project inputs changed after discovery."
    );
  }
  return value;
}
function validateInputs(value) {
  if (!isRecord(value)) invalidInputs();
  try {
    const projectId = createProjectId(value.projectId);
    const sourceMajor = createAngularMajor(value.sourceMajor);
    if (!isSha256(value.projectId) || !isSha256(value.inputFingerprint) || typeof value.projectShape !== "string" || typeof value.packageManager !== "string" || !Number.isSafeInteger(value.lockfileVersion) || !Array.isArray(value.nodeRanges) || !Array.isArray(value.runtimeCandidates) || value.metadataRuntimeVersion !== null && parseExactSemverVersion(value.metadataRuntimeVersion) === null || !Array.isArray(value.checks) || !Array.isArray(value.packages) || !Array.isArray(value.registryIdentities) || value.issues !== void 0 && !Array.isArray(value.issues) || typeof value.npmRange !== "string") {
      invalidInputs();
    }
    const gitStatus = value.gitStatus;
    const registryStatus = value.registryStatus;
    const dependencySourcesStatus = value.dependencySourcesStatus;
    if (!["clean", "dirty", "unavailable"].includes(String(gitStatus)) || !["trusted", "untrusted"].includes(String(registryStatus)) || !["safe", "unsafe"].includes(String(dependencySourcesStatus)) || value.nodeRanges.some((range) => !isValidSemverRange(range)) || !isValidSemverRange(value.npmRange) || !value.checks.every(isDiscoveryCheck) || !value.packages.every(isDiscoveryPackage) || !value.registryIdentities.every(isRegistryIdentity) || value.issues !== void 0 && !value.issues.every(isDiscoveryIssue)) {
      invalidInputs();
    }
    return {
      projectId,
      inputFingerprint: value.inputFingerprint,
      sourceMajor,
      projectShape: value.projectShape,
      packageManager: value.packageManager,
      lockfileVersion: value.lockfileVersion,
      gitStatus,
      registryStatus,
      dependencySourcesStatus,
      nodeRanges: value.nodeRanges,
      npmRange: value.npmRange,
      runtimeCandidates: value.runtimeCandidates,
      metadataRuntimeVersion: value.metadataRuntimeVersion,
      checks: value.checks,
      packages: value.packages,
      registryIdentities: value.registryIdentities,
      issues: value.issues
    };
  } catch (error) {
    if (error instanceof ApplicationError) throw error;
    invalidInputs();
  }
}
function collectBlockers(inputs, targetMajor) {
  const blockers = [];
  if (inputs.projectShape !== "root-angular-cli")
    blockers.push(
      blocker(
        "unsupported_project_layout",
        "Only a root Angular CLI project is supported."
      )
    );
  for (const issue of inputs.issues ?? []) blockers.push(issue);
  if (inputs.packageManager !== "npm")
    blockers.push(
      blocker("unsupported_package_manager", "Only npm is supported.")
    );
  if (![1, 2, 3].includes(inputs.lockfileVersion))
    blockers.push(
      blocker(
        "unsupported_lockfile",
        "The npm lockfile version is unsupported."
      )
    );
  if (inputs.gitStatus !== "clean")
    blockers.push(
      blocker("git_worktree_dirty", "The Git working tree must be clean.")
    );
  if (inputs.registryStatus !== "trusted")
    blockers.push(
      blocker(
        "registry_untrusted",
        "The configured package registry is not trusted."
      )
    );
  if (!inputs.registryIdentities.some(
    (identity) => identity.scope === "default" && identity.registryId === "npmjs"
  ) || inputs.registryIdentities.some(
    (identity) => identity.registryId === "untrusted"
  )) {
    blockers.push(
      blocker(
        "registry_identity_invalid",
        "The plan contains an untrusted or missing registry identity."
      )
    );
  }
  if (inputs.dependencySourcesStatus !== "safe")
    blockers.push(
      blocker(
        "unsafe_dependency_source",
        "Dependencies must use trusted npm registry sources."
      )
    );
  if (inputs.checks.some((check) => check.status === "blocked"))
    blockers.push(
      blocker(
        "project_check_blocked",
        "A required project check is not configured."
      )
    );
  const names = /* @__PURE__ */ new Set();
  for (const item of inputs.packages) {
    if (names.has(item.name))
      blockers.push(
        blocker(
          "duplicate_package_metadata",
          `Duplicate metadata for ${item.name}.`
        )
      );
    names.add(item.name);
    if (!parseExactSemverVersion(item.sourceVersion) || !parseExactSemverVersion(item.targetVersion) || !/^[a-z0-9][a-z0-9._:-]{0,127}$/.test(item.registryId)) {
      blockers.push(
        blocker(
          "package_metadata_invalid",
          `Invalid exact metadata for ${item.name}.`
        )
      );
    }
    if (item.name.startsWith("@angular/") && !item.name.startsWith("@angular-devkit/")) {
      const sourceVersion = parseExactSemverVersion(item.sourceVersion);
      const targetVersion = parseExactSemverVersion(item.targetVersion);
      if (!sourceVersion || sourceVersion.major !== inputs.sourceMajor || !targetVersion || targetVersion.major !== targetMajor)
        blockers.push(
          blocker(
            "angular_package_major_mismatch",
            `Registry metadata for ${item.name} does not match the requested N-to-N+1 transition.`
          )
        );
    }
  }
  if (!names.has("@angular/core"))
    blockers.push(
      blocker(
        "angular_core_metadata_missing",
        "Target @angular/core metadata is required."
      )
    );
  return blockers;
}
function isDiscoveryRecord(value) {
  return Boolean(
    isRecord(value) && value.schemaVersion === 1 && isSha256(value.projectId) && isSha256(value.inputFingerprint) && Number.isSafeInteger(value.sourceMajor) && Number.isSafeInteger(value.targetMajor) && ["ready", "runtime-install-required", "blocked"].includes(
      String(value.status)
    ) && [1, 2, 3].includes(Number(value.lockfileVersion)) && Array.isArray(value.checks) && value.checks.every(isDiscoveryCheck) && Array.isArray(value.packages) && value.packages.every(isDiscoveryPackage) && Array.isArray(value.registryIdentities) && value.registryIdentities.every(isRegistryIdentity) && isRecord(value.runtimePlan) && ["ready", "runtime-install-required", "blocked"].includes(
      String(value.runtimePlan.status)
    ) && Array.isArray(value.runtimePlan.nodeRanges) && value.runtimePlan.nodeRanges.every(isValidSemverRange) && isValidSemverRange(value.runtimePlan.npmRange) && Array.isArray(value.runtimePlan.operations) && value.runtimePlan.operations.every(
      (operation) => typeof operation === "string"
    ) && (value.runtimePlan.metadataNodeVersion === null || parseExactSemverVersion(value.runtimePlan.metadataNodeVersion) !== null) && isRuntimePlan(value.runtimePlan) && Array.isArray(value.blockers) && value.blockers.every(
      (item) => isRecord(item) && typeof item.code === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(item.code) && typeof item.message === "string"
    ) && isSha256(value.planHash) && value.targetMajor === value.sourceMajor + 1 && (value.status !== "ready" || value.runtimePlan.status === "ready" && value.runtimePlan.selected?.status === "installed" && value.blockers.length === 0) && (value.status !== "runtime-install-required" || value.runtimePlan.status === "runtime-install-required" && value.runtimePlan.selected?.status === "missing" && value.blockers.length === 0)
  );
}
function isDiscoveryCheck(value) {
  if (!isRecord(value)) return false;
  const executableValid = value.executable === null || typeof value.executable === "string" && value.executable.trim().length > 0 && !/[\0\r\n]/.test(value.executable);
  const reasonValid = value.reason === null || typeof value.reason === "string" && value.reason.trim().length > 0 && !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.reason);
  return typeof value.id === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(value.id) && ["configured", "not-configured", "blocked"].includes(
    String(value.status)
  ) && executableValid && Array.isArray(value.arguments) && value.arguments.every(
    (argument) => typeof argument === "string" && !/[\0\r\n]/.test(argument)
  ) && reasonValid && (value.status !== "configured" || typeof value.executable === "string" && value.reason === null) && (value.status !== "not-configured" || value.executable === null && value.arguments.length === 0 && typeof value.reason === "string") && (value.status !== "blocked" || typeof value.reason === "string");
}
function isDiscoveryPackage(value) {
  return Boolean(
    isRecord(value) && typeof value.name === "string" && /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(value.name) && typeof value.sourceVersion === "string" && typeof value.targetVersion === "string" && parseExactSemverVersion(value.sourceVersion) !== null && parseExactSemverVersion(value.targetVersion) !== null && typeof value.registryId === "string" && /^[a-z0-9][a-z0-9._:-]{0,127}$/.test(value.registryId) && (value.nodeRange === null || isValidSemverRange(value.nodeRange)) && Array.isArray(value.peerDependencies) && value.peerDependencies.every(
      (peer) => isRecord(peer) && typeof peer.name === "string" && /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(peer.name) && isValidSemverRange(peer.range)
    ) && typeof value.reason === "string" && value.reason.length > 0 && !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.reason)
  );
}
function isRegistryIdentity(value) {
  return Boolean(
    isRecord(value) && typeof value.scope === "string" && /^(?:default|@[a-z0-9._-]+)$/.test(value.scope) && typeof value.registryId === "string" && /^[a-z0-9][a-z0-9._:-]{0,127}$/.test(value.registryId)
  );
}
function isRuntimePlan(value) {
  const selected = value.selected;
  if (value.status === "ready")
    return isRuntimeCandidate(selected) && selected.status === "installed" && value.reason === null;
  if (value.status === "runtime-install-required")
    return isRuntimeCandidate(selected) && selected.status === "missing" && value.reason === "exact-runtime-missing";
  return value.status === "blocked" && selected === null && ["invalid-runtime-constraints", "no-compatible-runtime"].includes(
    String(value.reason)
  );
}
function isRuntimeCandidate(value) {
  return Boolean(
    isRecord(value) && parseExactSemverVersion(value.nodeVersion) !== null && (value.status === "installed" || value.status === "missing") && (value.status === "installed" ? parseExactSemverVersion(value.npmVersion) !== null : value.npmVersion === null)
  );
}
function isDiscoveryIssue(value) {
  return Boolean(
    isRecord(value) && typeof value.code === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(value.code) && typeof value.message === "string" && !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.message)
  );
}
function isRecord(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function isSha256(value) {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
}
function blocker(code, message) {
  return { code, message };
}
function invalidInputs() {
  throw new ApplicationError(
    "discovery_inputs_invalid",
    "Project discovery returned malformed or unsupported input."
  );
}

// application/start-run.ts
async function startRun(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || !Number.isSafeInteger(request.targetMajor)) {
    throw new ApplicationError(
      "start_request_invalid",
      "A project root and target major are required."
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery."
    );
  }
  let result;
  let failure;
  try {
    const current = await ports.reader.read(
      request.projectRoot,
      request.targetMajor
    );
    const context = readCurrentContext(current);
    const storedPlan = await ports.discoveries.read(request.projectRoot);
    const plan = await readValidatedDiscoveryRecord(
      storedPlan,
      {
        projectId: context.projectId,
        inputFingerprint: context.inputFingerprint,
        targetMajor: request.targetMajor
      },
      ports.hasher
    );
    assertStartablePlan(plan, context);
    const previous = await ports.runRecords.read(request.projectRoot);
    if (previous !== null) {
      const oldRun = await readValidatedRunRecord(previous, ports.hasher);
      if (oldRun.state.status !== "completed") {
        throw new ApplicationError(
          "run_already_active",
          "The existing run must reach a terminal state before another can start."
        );
      }
    }
    result = await createRunRecord(plan, ports.ids, ports.hasher);
    await ports.hookRuntime.deploy(request.projectRoot);
    await ports.runRecords.write(request.projectRoot, result);
  } catch (error) {
    failure = error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
async function readValidatedRunRecord(value, hasher) {
  if (!isRunRecord(value)) {
    throw new ApplicationError(
      "run_record_invalid",
      "The persisted run record is invalid."
    );
  }
  const { recordHash, ...content } = value;
  if (await hasher.hash(content) !== recordHash) {
    throw new ApplicationError(
      "run_record_integrity_failed",
      "The persisted run record has been altered."
    );
  }
  await readValidatedDiscoveryRecord(
    value.discoveryPlan,
    {
      projectId: value.state.projectId,
      inputFingerprint: value.discoveryPlan.inputFingerprint,
      targetMajor: value.state.targetMajor
    },
    hasher
  );
  if (value.state.projectId !== value.discoveryPlan.projectId || value.state.sourceMajor !== value.discoveryPlan.sourceMajor || value.state.targetMajor !== value.discoveryPlan.targetMajor) {
    throw new ApplicationError(
      "run_record_context_mismatch",
      "The run and discovery plan do not describe the same migration."
    );
  }
  return value;
}
async function createRunRecord(plan, ids, hasher) {
  const state = createInitialRunState({
    runId: ids.create(),
    projectId: plan.projectId,
    sourceMajor: plan.sourceMajor,
    targetMajor: plan.targetMajor
  });
  const content = {
    schemaVersion: 1,
    state,
    discoveryPlan: plan,
    events: [
      {
        sequence: 0,
        type: "run-started",
        stage: state.stage,
        status: state.status,
        revision: state.revision
      }
    ],
    checkpoints: [],
    diagnostic: null
  };
  return sealRunRecord(content, hasher);
}
async function sealRunRecord(content, hasher) {
  return { ...content, recordHash: await hasher.hash(content) };
}
function readCurrentContext(value) {
  if (!isRecord2(value) || typeof value.projectId !== "string" || !/^sha256:[a-f0-9]{64}$/.test(value.projectId) || typeof value.inputFingerprint !== "string" || !/^sha256:[a-f0-9]{64}$/.test(value.inputFingerprint) || !Number.isSafeInteger(value.sourceMajor) || !Array.isArray(value.runtimeCandidates)) {
    throw new ApplicationError(
      "project_context_invalid",
      "The current project context is invalid."
    );
  }
  try {
    createProjectId(value.projectId);
    createAngularMajor(value.sourceMajor);
  } catch {
    throw new ApplicationError(
      "project_context_invalid",
      "The current project identity or Angular major is invalid."
    );
  }
  return {
    projectId: value.projectId,
    inputFingerprint: value.inputFingerprint,
    sourceMajor: value.sourceMajor,
    gitStatus: typeof value.gitStatus === "string" ? value.gitStatus : "",
    runtimeCandidates: value.runtimeCandidates
  };
}
function assertStartablePlan(plan, context) {
  if (plan.status !== "ready" || plan.runtimePlan.status !== "ready") {
    throw new ApplicationError(
      "discovery_not_ready",
      "Only a ready discovery plan can start a run."
    );
  }
  if (context.gitStatus !== "clean") {
    throw new ApplicationError(
      "project_not_clean",
      "The project Git working tree must be clean at run start."
    );
  }
  if (context.sourceMajor !== plan.sourceMajor) {
    throw new ApplicationError(
      "project_major_mismatch",
      "The current Angular major differs from the discovery plan."
    );
  }
  const selected = plan.runtimePlan.selected;
  const available = context.runtimeCandidates.some((candidate) => {
    if (!isRecord2(candidate) || candidate.status !== "installed") return false;
    const node = parseExactSemverVersion(candidate.nodeVersion);
    const npm = parseExactSemverVersion(candidate.npmVersion);
    return node?.version === selected?.nodeVersion && npm?.version === selected?.npmVersion;
  });
  if (!selected || selected.status !== "installed" || !available) {
    throw new ApplicationError(
      "planned_runtime_unavailable",
      "The exact planned Node/npm runtime is no longer available."
    );
  }
}
function isRunRecord(value) {
  return Boolean(
    isRecord2(value) && value.schemaVersion === 1 && isValidPersistedRunState(value.state) && Array.isArray(value.events) && value.events.every(isRunEvent) && value.events.every((event, index) => event.sequence === index) && hasValidEventSequence(value.events, value.state) && Array.isArray(value.checkpoints) && value.checkpoints.every(isRunCheckpoint) && value.checkpoints.every(
      (checkpoint, index) => checkpoint.sequence === index
    ) && hasValidCheckpointPairs(value.checkpoints) && isRecord2(value.discoveryPlan) && (value.diagnostic === null || isSafeDiagnostic(value.diagnostic)) && typeof value.recordHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.recordHash)
  );
}
function isValidPersistedRunState(value) {
  return Boolean(
    isRecord2(value) && isValidRunState(value) && typeof value.runId === "string" && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.runId) && typeof value.projectId === "string" && /^sha256:[a-f0-9]{64}$/.test(value.projectId) && Number.isSafeInteger(value.sourceMajor) && Number.isSafeInteger(value.targetMajor) && value.targetMajor === value.sourceMajor + 1 && Number.isSafeInteger(value.revision) && value.revision >= 0
  );
}
function isRunEvent(value) {
  return Boolean(
    isRecord2(value) && Number.isSafeInteger(value.sequence) && [
      "run-started",
      "stage-started",
      "stage-completed",
      "stage-blocked",
      "stage-failed",
      "check-skipped",
      "stage-needs-repair",
      "repair-accepted",
      "repair-rejected",
      "baseline-dependency-approval-started",
      "baseline-dependency-approval-failed",
      "baseline-dependencies-approved",
      "documentation-research-recorded",
      "documentation-publish-started",
      "documentation-published"
    ].includes(String(value.type)) && [
      "baseline",
      "resolve",
      "update-angular",
      "update-dependencies",
      "install",
      "validate",
      "document",
      "done"
    ].includes(String(value.stage)) && [
      "running",
      "needs-repair",
      "verified",
      "completed",
      "blocked",
      "failed"
    ].includes(String(value.status)) && Number.isSafeInteger(value.revision) && value.revision >= 0 && (value.type !== "check-skipped" || isCheckSkipDetails(value.skip)) && (value.type === "check-skipped" || value.skip === void 0) && (["repair-accepted", "repair-rejected"].includes(String(value.type)) ? isRepairEventDetails(value.repair) : value.repair === void 0) && ([
      "baseline-dependency-approval-started",
      "baseline-dependency-approval-failed",
      "baseline-dependencies-approved"
    ].includes(String(value.type)) ? isBaselineApprovalDetails(value.baselineApproval) : value.baselineApproval === void 0) && ([
      "documentation-research-recorded",
      "documentation-publish-started",
      "documentation-published"
    ].includes(String(value.type)) ? isDocumentationEventDetails(value.documentation) : value.documentation === void 0)
  );
}
function isRunCheckpoint(value) {
  return Boolean(
    isRecord2(value) && Number.isSafeInteger(value.sequence) && [
      "baseline",
      "resolve",
      "update-angular",
      "update-dependencies",
      "install",
      "validate",
      "document",
      "done"
    ].includes(String(value.stage)) && typeof value.operationId === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(value.operationId) && (value.phase === "before" || value.phase === "after" || value.phase === "skipped") && typeof value.projectFingerprint === "string" && /^sha256:[a-f0-9]{64}$/.test(value.projectFingerprint) && typeof value.idempotencyKey === "string" && /^[0-9a-f-]{36}:[a-z-]+:[a-z][a-z0-9-]{0,63}:(?:before|after|skipped)$/.test(
      value.idempotencyKey
    )
  );
}
function hasValidCheckpointPairs(checkpoints) {
  let pending;
  let previousStageIndex = -1;
  const keys = /* @__PURE__ */ new Set();
  for (const checkpoint of checkpoints) {
    const stageIndex = RUN_STAGE_ORDER.indexOf(checkpoint.stage);
    if (stageIndex < previousStageIndex || stageIndex > previousStageIndex + 1) {
      return false;
    }
    previousStageIndex = stageIndex;
    if (keys.has(checkpoint.idempotencyKey)) return false;
    keys.add(checkpoint.idempotencyKey);
    if (checkpoint.phase === "before") {
      if (pending) return false;
      pending = checkpoint;
      continue;
    }
    if (!pending || pending.stage !== checkpoint.stage || pending.operationId !== checkpoint.operationId) {
      return false;
    }
    pending = void 0;
  }
  return true;
}
function hasValidEventSequence(events, state) {
  if (events.length === 0 || events[0].type !== "run-started" || events[0].stage !== "baseline" || events[0].status !== "running" || events[0].revision !== 0) {
    return false;
  }
  let stage = "baseline";
  let status = "running";
  let revision = 0;
  let stageStarted = false;
  let terminal = false;
  let pendingBaselineApproval;
  let pendingDocumentationPublication;
  let documentationPublished = false;
  for (const event of events.slice(1)) {
    if (event.type === "documentation-research-recorded") {
      if (!isDocumentationEventDetails(event.documentation) || event.documentation.outcome !== "research-recorded" || !["running", "verified"].includes(status) || event.stage !== stage || event.status !== status || event.revision !== revision || pendingDocumentationPublication) {
        return false;
      }
      continue;
    }
    if (event.type === "documentation-publish-started") {
      if (status !== "verified" || stage !== "document" || event.stage !== stage || event.status !== status || event.revision !== revision || !isDocumentationEventDetails(event.documentation) || event.documentation.outcome !== "publish-started" || pendingDocumentationPublication || documentationPublished) {
        return false;
      }
      pendingDocumentationPublication = event.documentation;
      continue;
    }
    if (event.type === "documentation-published") {
      if (status !== "verified" || stage !== "document" || event.stage !== stage || event.status !== status || event.revision !== revision || !isDocumentationEventDetails(event.documentation) || event.documentation.outcome !== "published" || !matchesDocumentationPublication(
        pendingDocumentationPublication,
        event.documentation
      )) {
        return false;
      }
      pendingDocumentationPublication = void 0;
      documentationPublished = true;
      continue;
    }
    if (terminal) {
      if (event.type === "baseline-dependency-approval-started" && status === "blocked" && stage === "baseline" && event.stage === stage && event.status === "blocked" && event.revision === revision && isBaselineApprovalDetails(event.baselineApproval) && event.baselineApproval.outcome === "started" && !pendingBaselineApproval) {
        pendingBaselineApproval = event.baselineApproval;
        continue;
      }
      if (event.type === "baseline-dependency-approval-failed" && status === "blocked" && stage === "baseline" && event.stage === stage && event.status === "blocked" && event.revision === revision && isBaselineApprovalDetails(event.baselineApproval) && event.baselineApproval.outcome === "failed" && matchesBaselineApproval(pendingBaselineApproval, event.baselineApproval)) {
        pendingBaselineApproval = void 0;
        continue;
      }
      if (event.type === "baseline-dependencies-approved" && status === "blocked" && stage === "baseline" && event.stage === stage && event.status === "running" && event.revision === revision + 1 && isBaselineApprovalDetails(event.baselineApproval) && event.baselineApproval.outcome === "installed" && matchesBaselineApproval(
        pendingBaselineApproval,
        event.baselineApproval
      ) && event.baselineApproval.packageStateHash !== null) {
        pendingBaselineApproval = void 0;
        status = "running";
        revision += 1;
        terminal = false;
        continue;
      }
      if (event.type === "repair-rejected" && status === "needs-repair") {
        if (event.stage !== stage || event.status !== "needs-repair" || event.revision !== revision || !isRepairEventDetails(event.repair) || event.repair.outcome !== "rejected") {
          return false;
        }
        continue;
      }
      if (event.stage !== stage || event.revision !== revision + 1 || !(event.type === "check-skipped" && status === "blocked" && event.status === "running" && isCheckSkipDetails(event.skip) || event.type === "repair-accepted" && status === "needs-repair" && event.status === "running" && isRepairEventDetails(event.repair) && event.repair.outcome === "accepted")) {
        return false;
      }
      status = event.status;
      revision += 1;
      terminal = false;
      continue;
    }
    if (event.type === "stage-started") {
      if (stageStarted || status !== "running" || event.stage !== stage || event.status !== status || event.revision !== revision) {
        return false;
      }
      stageStarted = true;
      continue;
    }
    if (event.type === "stage-completed") {
      if (!stageStarted || event.stage !== stage || event.revision !== revision + 1 || event.status !== (stage === "validate" ? "verified" : "running")) {
        return false;
      }
      status = event.status;
      revision += 1;
      stage = nextRunStage(stage);
      stageStarted = false;
      continue;
    }
    if (!["stage-blocked", "stage-failed", "stage-needs-repair"].includes(
      event.type
    ) || event.stage !== stage || event.status !== (event.type === "stage-blocked" ? "blocked" : event.type === "stage-failed" ? "failed" : "needs-repair") || event.revision !== revision + 1) {
      return false;
    }
    status = event.status;
    revision += 1;
    terminal = true;
  }
  return stage === state.stage && status === state.status && revision === state.revision && (pendingBaselineApproval === void 0 || status === "blocked" && events.at(-1)?.type === "baseline-dependency-approval-started") && (pendingDocumentationPublication === void 0 || status === "verified" && events.at(-1)?.type === "documentation-publish-started");
}
function isCheckSkipDetails(value) {
  return Boolean(
    isRecord2(value) && typeof value.checkId === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(value.checkId) && typeof value.reason === "string" && value.reason.trim().length > 0 && value.reason.length <= 2e3 && value.confirmed === true
  );
}
function isRepairEventDetails(value) {
  return Boolean(
    isRecord2(value) && Number.isSafeInteger(value.attempt) && value.attempt >= 1 && value.attempt <= 3 && typeof value.fingerprint === "string" && /^sha256:[a-f0-9]{64}$/.test(value.fingerprint) && typeof value.submissionHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.submissionHash) && Array.isArray(value.changedPaths) && value.changedPaths.length > 0 && value.changedPaths.every(
      (file) => typeof file === "string" && /^src\/[A-Za-z0-9._/-]+$/.test(file) && !file.split("/").includes("..")
    ) && ["accepted", "rejected"].includes(String(value.outcome))
  );
}
function isBaselineApprovalDetails(value) {
  return Boolean(
    isRecord2(value) && typeof value.proposalHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.proposalHash) && Array.isArray(value.packages) && value.packages.length > 0 && value.packages.every(
      (item) => isRecord2(item) && typeof item.name === "string" && /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) && !item.name.startsWith("@angular/") && typeof item.version === "string" && parseExactSemverVersion(item.version)?.version === item.version
    ) && ["started", "failed", "installed"].includes(String(value.outcome)) && (value.packageStateHash === null || typeof value.packageStateHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.packageStateHash))
  );
}
function matchesBaselineApproval(started, finished) {
  return Boolean(
    started && started.proposalHash === finished.proposalHash && JSON.stringify(started.packages) === JSON.stringify(finished.packages)
  );
}
function isDocumentationEventDetails(value) {
  if (!isRecord2(value) || typeof value.researchHash !== "string" || !/^sha256:[a-f0-9]{64}$/.test(value.researchHash)) {
    return false;
  }
  if (value.outcome === "research-recorded") {
    return value.proposalHash === null && value.filesHash === null && value.outputDirectory === null && value.expectedGitSnapshot === null;
  }
  return ["publish-started", "published"].includes(String(value.outcome)) && typeof value.proposalHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.proposalHash) && typeof value.filesHash === "string" && /^sha256:[a-f0-9]{64}$/.test(value.filesHash) && typeof value.outputDirectory === "string" && /^docs\/migration\/v[1-9]\d*$/.test(value.outputDirectory) && isDocumentationGitSnapshot(value.expectedGitSnapshot);
}
function isDocumentationGitSnapshot(value) {
  return Boolean(
    isRecord2(value) && typeof value.head === "string" && /^[a-f0-9]{40,64}$/.test(value.head) && Array.isArray(value.changes) && value.changes.length <= 2e3 && value.changes.every(
      (item) => isRecord2(item) && typeof item.path === "string" && item.path.length > 0 && item.path.length <= 1024 && !item.path.includes("\0") && typeof item.status === "string" && /^[ MADRCU?!]{2}$/.test(item.status)
    )
  );
}
function matchesDocumentationPublication(started, published) {
  return Boolean(
    started && started.outcome === "publish-started" && started.researchHash === published.researchHash && started.proposalHash === published.proposalHash && started.filesHash === published.filesHash && started.outputDirectory === published.outputDirectory && JSON.stringify(started.expectedGitSnapshot) === JSON.stringify(published.expectedGitSnapshot)
  );
}
var RUN_STAGE_ORDER = [
  "baseline",
  "resolve",
  "update-angular",
  "update-dependencies",
  "install",
  "validate",
  "document",
  "done"
];
function nextRunStage(stage) {
  const index = RUN_STAGE_ORDER.indexOf(stage);
  return RUN_STAGE_ORDER[Math.min(index + 1, RUN_STAGE_ORDER.length - 1)];
}
function isSafeDiagnostic(value) {
  return Boolean(
    isRecord2(value) && typeof value.code === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(value.code) && typeof value.message === "string" && value.message.length > 0 && !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(value.message)
  );
}
function isRecord2(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

// application/approve-check-skip.ts
var SKIPPABLE_BASELINE_CHECKS = /* @__PURE__ */ new Set([
  "typecheck",
  "lint",
  "unit-test",
  "e2e"
]);
var CRITICAL_CHECKS = /* @__PURE__ */ new Set(["install", "dependency-tree", "build"]);
async function approveCheckSkip(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || typeof request.checkId !== "string" || typeof request.reason !== "string" || request.reason.trim().length === 0 || request.reason.length > 2e3 || request.confirmed !== true) {
    throw new ApplicationError(
      request?.confirmed === true ? "skip_request_invalid" : "confirmation_required",
      request?.confirmed === true ? "A check id and a reason of at most 2000 characters are required." : "Skipping a project check requires explicit confirmation.",
      "blocked"
    );
  }
  if (CRITICAL_CHECKS.has(request.checkId)) {
    throw new ApplicationError(
      "critical_check_cannot_be_skipped",
      "Install, dependency-tree, and build checks cannot be skipped.",
      "blocked"
    );
  }
  if (!SKIPPABLE_BASELINE_CHECKS.has(request.checkId)) {
    throw new ApplicationError(
      "check_not_skippable",
      "The requested check is not in the baseline skip allowlist.",
      "blocked"
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery.",
      "blocked"
    );
  }
  let failure;
  try {
    const stored = await ports.records.read(request.projectRoot);
    if (stored === null) {
      throw new ApplicationError(
        "run_not_found",
        "No run exists for this project.",
        "blocked"
      );
    }
    const record = await readValidatedRunRecord(stored, ports.hasher);
    const latest = record.checkpoints.at(-1);
    if (record.state.runId !== request.runId) {
      throw new ApplicationError(
        "run_context_mismatch",
        "The skip does not belong to the current run.",
        "blocked"
      );
    }
    if (record.state.status !== "blocked" || record.state.stage !== "baseline" || latest?.phase !== "before" || latest.operationId !== `baseline-${request.checkId}` || record.diagnostic === null || !record.discoveryPlan.checks.some(
      (check) => check.id === request.checkId && check.status === "configured" && check.executable === "npm"
    )) {
      throw new ApplicationError(
        "skip_context_unavailable",
        "A skip requires the matching configured baseline check to be blocked.",
        "blocked"
      );
    }
    const fingerprint = await ports.fingerprints.readFingerprint(
      request.projectRoot
    );
    if (fingerprint !== latest.projectFingerprint) {
      throw new ApplicationError(
        "project_fingerprint_changed",
        "Project inputs changed after the failed check.",
        "blocked"
      );
    }
    const transition = decideRunTransition(
      record.state,
      { status: "running", stage: "baseline" },
      "human-confirmed-retry"
    );
    if (transition.outcome !== "allowed") {
      throw new ApplicationError(
        "skip_transition_rejected",
        "The blocked run cannot resume under the current state policy.",
        "blocked"
      );
    }
    const checkpoint = {
      sequence: record.checkpoints.length,
      stage: "baseline",
      operationId: latest.operationId,
      phase: "skipped",
      projectFingerprint: fingerprint,
      idempotencyKey: `${record.state.runId}:baseline:${latest.operationId}:skipped`
    };
    const { recordHash: _previousHash, ...unsignedRecord } = record;
    const content = {
      ...unsignedRecord,
      state: transition.value,
      diagnostic: null,
      checkpoints: [...record.checkpoints, checkpoint],
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "check-skipped",
          stage: "baseline",
          status: "running",
          revision: transition.value.revision,
          skip: {
            checkId: request.checkId,
            reason: request.reason.trim(),
            confirmed: true
          }
        }
      ]
    };
    const updated = await sealRunRecord(content, ports.hasher);
    await ports.records.write(request.projectRoot, updated);
  } catch (error) {
    failure = error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return {
    runId: request.runId,
    status: "running",
    stage: "baseline",
    checkId: request.checkId,
    reason: request.reason.trim()
  };
}

// application/approve-runtime-install.ts
async function approveRuntimeInstall(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || !Number.isSafeInteger(request.targetMajor) || typeof request.proposalHash !== "string" || !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) || request.confirmed !== true) {
    throw new ApplicationError(
      request?.confirmed === true ? "runtime_approval_request_invalid" : "confirmation_required",
      request?.confirmed === true ? "A current runtime proposal hash is required." : "Runtime installation requires explicit confirmation.",
      "blocked"
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery.",
      "blocked"
    );
  }
  let result;
  let failure;
  try {
    await assertNoActiveRun(request.projectRoot, ports);
    const history = await readAuditHistory(request.projectRoot, ports);
    if (history.pending) {
      throw new ApplicationError(
        "runtime_install_recovery_required",
        "A previous runtime installation has an unconfirmed outcome.",
        "blocked"
      );
    }
    const plan = await discoverProject(request, ports);
    if (plan.planHash !== request.proposalHash) {
      throw new ApplicationError(
        "runtime_proposal_stale",
        "The runtime proposal changed; review the current discovery before approving it.",
        "blocked"
      );
    }
    const nodeVersion = plan.runtimePlan.selected?.nodeVersion;
    if (plan.status !== "runtime-install-required" || plan.runtimePlan.status !== "runtime-install-required" || plan.runtimePlan.selected?.status !== "missing" || !nodeVersion || !parseExactSemverVersion(nodeVersion)) {
      throw new ApplicationError(
        "runtime_install_not_required",
        "The current discovery has no exact missing-runtime proposal.",
        "blocked"
      );
    }
    if (history.events.some((event) => event.proposalHash === plan.planHash)) {
      throw new ApplicationError(
        "runtime_install_already_attempted",
        "This runtime proposal was already attempted and cannot be replayed.",
        "blocked"
      );
    }
    const started = await createAuditEvent(
      history.events,
      plan,
      nodeVersion,
      "started",
      ports
    );
    await ports.audit.write(request.projectRoot, [...history.events, started]);
    let installOutcome;
    try {
      installOutcome = await ports.installer.install(
        request.projectRoot,
        nodeVersion
      );
    } catch {
      installOutcome = "failed";
    }
    if (installOutcome !== "installed") {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports
      );
      throw new ApplicationError(
        "runtime_install_failed",
        "The approved exact runtime could not be installed and verified.",
        "blocked"
      );
    }
    let refreshed;
    try {
      refreshed = await discoverProject(request, ports);
    } catch {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports
      );
      throw new ApplicationError(
        "runtime_install_unverified",
        "The installed runtime could not be verified by a fresh discovery.",
        "blocked"
      );
    }
    if (refreshed.status !== "ready" || refreshed.runtimePlan.status !== "ready" || refreshed.runtimePlan.selected?.nodeVersion !== nodeVersion || refreshed.runtimePlan.selected.status !== "installed") {
      await appendAuditOutcome(
        request.projectRoot,
        [...history.events, started],
        plan,
        nodeVersion,
        "failed",
        ports
      );
      throw new ApplicationError(
        "runtime_install_unverified",
        "The installed runtime does not satisfy the current Node and npm constraints.",
        "blocked"
      );
    }
    await appendAuditOutcome(
      request.projectRoot,
      [...history.events, started],
      plan,
      nodeVersion,
      "installed",
      ports
    );
    result = {
      status: "installed",
      proposalHash: plan.planHash,
      nodeVersion,
      discovery: refreshed
    };
  } catch (error) {
    failure = error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
async function assertNoActiveRun(projectRoot, ports) {
  const stored = await ports.runRecords.read(projectRoot);
  if (stored === null) return;
  const run = await readValidatedRunRecord(stored, ports.hasher);
  if (run.state.status !== "completed") {
    throw new ApplicationError(
      "run_already_active",
      "Runtime installation cannot run while a migration run is active.",
      "blocked"
    );
  }
}
async function readAuditHistory(projectRoot, ports) {
  const value = await ports.audit.read(projectRoot);
  if (value === null) return { events: [], pending: false };
  if (!Array.isArray(value)) return invalidAudit();
  const events = [];
  let pending;
  for (const item of value) {
    if (!isAuditEvent(item) || item.sequence !== events.length)
      return invalidAudit();
    const { eventHash, ...content } = item;
    if (item.previousHash !== (events.at(-1)?.eventHash ?? null) || await ports.hasher.hash(content) !== eventHash) {
      return invalidAudit();
    }
    if (item.outcome === "started") {
      if (pending) return invalidAudit();
      pending = item;
    } else {
      if (!pending || pending.projectId !== item.projectId || pending.inputFingerprint !== item.inputFingerprint || pending.proposalHash !== item.proposalHash || pending.nodeVersion !== item.nodeVersion) {
        return invalidAudit();
      }
      pending = void 0;
    }
    events.push(item);
  }
  return { events, pending: pending !== void 0 };
}
async function createAuditEvent(events, plan, nodeVersion, outcome, ports) {
  const content = {
    sequence: events.length,
    projectId: plan.projectId,
    inputFingerprint: plan.inputFingerprint,
    proposalHash: plan.planHash,
    nodeVersion,
    outcome,
    previousHash: events.at(-1)?.eventHash ?? null
  };
  return { ...content, eventHash: await ports.hasher.hash(content) };
}
async function appendAuditOutcome(projectRoot, events, plan, nodeVersion, outcome, ports) {
  const event = await createAuditEvent(
    events,
    plan,
    nodeVersion,
    outcome,
    ports
  );
  await ports.audit.write(projectRoot, [...events, event]);
}
function isAuditEvent(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const event = value;
  return Number.isSafeInteger(event.sequence) && typeof event.projectId === "string" && /^sha256:[a-f0-9]{64}$/.test(event.projectId) && typeof event.inputFingerprint === "string" && /^sha256:[a-f0-9]{64}$/.test(event.inputFingerprint) && typeof event.proposalHash === "string" && /^sha256:[a-f0-9]{64}$/.test(event.proposalHash) && typeof event.nodeVersion === "string" && parseExactSemverVersion(event.nodeVersion) !== null && ["started", "installed", "failed"].includes(event.outcome) && (event.previousHash === null || typeof event.previousHash === "string" && /^sha256:[a-f0-9]{64}$/.test(event.previousHash)) && typeof event.eventHash === "string" && /^sha256:[a-f0-9]{64}$/.test(event.eventHash);
}
function invalidAudit() {
  throw new ApplicationError(
    "runtime_install_audit_invalid",
    "Runtime installation audit history is invalid or corrupted.",
    "blocked"
  );
}

// application/baseline-dependencies.ts
async function getBaselineDependencyContext(request, ports) {
  const run = await readBaselineFailure(request, ports);
  return createProposal(request.projectRoot, run, ports);
}
async function approveBaselineDependencies(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || typeof request.proposalHash !== "string" || !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) || request.confirmed !== true) {
    throw blocked2(
      request?.confirmed === true ? "baseline_dependency_approval_invalid" : "confirmation_required",
      request?.confirmed === true ? "A current baseline dependency proposal hash is required." : "Baseline dependency installation requires explicit confirmation."
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw blocked2(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery."
    );
  }
  let result;
  let failure;
  try {
    let run = await readBaselineFailure(request, ports);
    const proposal = await createProposal(request.projectRoot, run, ports);
    if (proposal.proposalHash !== request.proposalHash) {
      throw blocked2(
        "baseline_dependency_proposal_stale",
        "The baseline dependency proposal changed; request confirmation again."
      );
    }
    if (run.events.some(
      (event) => event.baselineApproval?.proposalHash === proposal.proposalHash
    )) {
      throw blocked2(
        "baseline_dependency_approval_recovery_required",
        "This dependency proposal was already attempted and cannot be replayed."
      );
    }
    const latest = run.checkpoints.at(-1);
    const packages = proposal.packages.map(({ name, installVersion }) => ({
      name,
      version: installVersion
    }));
    const started = {
      sequence: run.events.length,
      type: "baseline-dependency-approval-started",
      stage: "baseline",
      status: "blocked",
      revision: run.state.revision,
      baselineApproval: {
        proposalHash: proposal.proposalHash,
        packages,
        outcome: "started",
        packageStateHash: null
      }
    };
    run = await saveRun(
      run,
      request.projectRoot,
      { events: [...run.events, started] },
      ports
    );
    let installed;
    try {
      installed = await ports.installer.install({
        projectRoot: request.projectRoot,
        runId: request.runId,
        nodeVersion: run.discoveryPlan.runtimePlan.selected.nodeVersion,
        packages: proposal.packages
      });
    } catch {
      installed = { outcome: "failed", packageStateHash: null };
    }
    const currentFingerprint = await ports.fingerprints.readFingerprint(request.projectRoot).catch(() => "");
    if (installed.outcome !== "installed" || !installed.packageStateHash || !/^sha256:[a-f0-9]{64}$/.test(installed.packageStateHash) || !/^sha256:[a-f0-9]{64}$/.test(currentFingerprint)) {
      const failed = {
        sequence: run.events.length,
        type: "baseline-dependency-approval-failed",
        stage: "baseline",
        status: "blocked",
        revision: run.state.revision,
        baselineApproval: {
          ...started.baselineApproval,
          outcome: "failed",
          packageStateHash: installed.packageStateHash
        }
      };
      await saveRun(
        run,
        request.projectRoot,
        { events: [...run.events, failed] },
        ports
      );
      throw blocked2(
        "baseline_dependency_install_failed",
        "Approved dependencies did not produce a verified dependency tree and controlled commit."
      );
    }
    const transition = decideRunTransition(
      run.state,
      { status: "running", stage: "baseline" },
      "human-confirmed-retry"
    );
    if (transition.outcome !== "allowed") {
      throw blocked2(
        "baseline_dependency_transition_rejected",
        "The verified dependency change cannot resume the current run."
      );
    }
    const checkpoint = {
      sequence: run.checkpoints.length,
      stage: "baseline",
      operationId: latest.operationId,
      phase: "after",
      projectFingerprint: currentFingerprint,
      idempotencyKey: `${run.state.runId}:baseline:${latest.operationId}:after`
    };
    const approved = {
      sequence: run.events.length,
      type: "baseline-dependencies-approved",
      stage: "baseline",
      status: "running",
      revision: transition.value.revision,
      baselineApproval: {
        ...started.baselineApproval,
        outcome: "installed",
        packageStateHash: installed.packageStateHash
      }
    };
    await saveRun(
      run,
      request.projectRoot,
      {
        state: transition.value,
        diagnostic: null,
        checkpoints: [...run.checkpoints, checkpoint],
        events: [...run.events, approved]
      },
      ports
    );
    result = {
      runId: request.runId,
      status: "running",
      stage: "baseline",
      proposalHash: proposal.proposalHash,
      packageStateHash: installed.packageStateHash,
      packages: proposal.packages
    };
  } catch (error) {
    failure = error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
async function readBaselineFailure(request, ports) {
  if (typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || request.runId.trim().length === 0) {
    throw blocked2(
      "baseline_dependency_request_invalid",
      "A project root and run id are required."
    );
  }
  const stored = await ports.records.read(request.projectRoot);
  if (stored === null)
    throw blocked2("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(stored, ports.hasher);
  const latest = run.checkpoints.at(-1);
  if (run.state.runId !== request.runId || run.state.status !== "blocked" || run.state.stage !== "baseline" || run.diagnostic?.code !== "process_nonzero_exit" || latest?.stage !== "baseline" || latest.operationId !== "baseline-dependency-tree" || latest.phase !== "before") {
    throw blocked2(
      "baseline_dependency_context_unavailable",
      "Baseline dependency approval requires a failed dependency-tree check in the active run."
    );
  }
  if (run.events.at(-1)?.type === "baseline-dependency-approval-started") {
    throw blocked2(
      "baseline_dependency_approval_recovery_required",
      "A previous dependency installation has an unconfirmed outcome."
    );
  }
  return run;
}
async function createProposal(projectRoot, run, ports) {
  const checkpoint = run.checkpoints.at(-1);
  const fingerprint = await ports.fingerprints.readFingerprint(projectRoot);
  if (fingerprint !== checkpoint.projectFingerprint) {
    throw blocked2(
      "baseline_dependency_context_stale",
      "Project inputs changed after the dependency-tree check failed."
    );
  }
  const packages = validateProposalPackages(
    await ports.proposals.read(projectRoot, run)
  );
  const content = {
    schemaVersion: 1,
    runId: run.state.runId,
    projectId: run.state.projectId,
    fingerprint,
    failedCheck: "dependency-tree",
    packages
  };
  const proposalHash = await ports.hasher.hash(content);
  if (!/^sha256:[a-f0-9]{64}$/.test(proposalHash)) {
    throw blocked2(
      "baseline_dependency_hash_invalid",
      "The dependency proposal could not be integrity-bound."
    );
  }
  return { ...content, proposalHash };
}
function validateProposalPackages(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 50) {
    throw blocked2(
      "baseline_dependency_proposal_invalid",
      "No bounded missing-peer proposal is available."
    );
  }
  const names = /* @__PURE__ */ new Set();
  const packages = [];
  for (const item of value) {
    if (!isRecord3(item) || typeof item.name !== "string" || !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) || item.name.startsWith("@angular/") || names.has(item.name) || typeof item.installVersion !== "string" || parseExactSemverVersion(item.installVersion)?.version !== item.installVersion || !Array.isArray(item.requiredRanges) || item.requiredRanges.length === 0 || item.requiredRanges.length > 20 || !item.requiredRanges.every(isValidSemverRange) || !satisfiesAllSemverRanges(item.installVersion, item.requiredRanges) || !Array.isArray(item.requiredBy) || item.requiredBy.length === 0 || item.requiredBy.length > 100 || !item.requiredBy.every(
      (parent) => typeof parent === "string" && parent.length <= 256 && !/[\0\r\n]/.test(parent)
    )) {
      throw blocked2(
        "baseline_dependency_proposal_invalid",
        "The dependency proposal contains invalid or incompatible package metadata."
      );
    }
    names.add(item.name);
    packages.push({
      name: item.name,
      installVersion: item.installVersion,
      requiredRanges: [...new Set(item.requiredRanges)].sort(),
      requiredBy: [...new Set(item.requiredBy)].sort()
    });
  }
  return packages.sort((left, right) => left.name.localeCompare(right.name));
}
async function saveRun(run, projectRoot, changes, ports) {
  const { recordHash: _oldHash, ...unsigned } = run;
  const updated = await sealRunRecord(
    { ...unsigned, ...changes },
    ports.hasher
  );
  await ports.records.write(projectRoot, updated);
  return updated;
}
function isRecord3(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function blocked2(code, message) {
  return new ApplicationError(code, message, "blocked");
}

// domain/documentation-policy.ts
var REQUIRED_MIGRATION_DOCUMENTS = [
  "README.md",
  "changes.md",
  "dependencies.md",
  "errors-and-repairs.md",
  "new-concepts.md",
  "sources.md",
  "validation.md",
  "warnings.md"
];
function migrationDocumentationDirectory(targetMajor) {
  if (!Number.isSafeInteger(targetMajor) || targetMajor < 1) {
    throw new RangeError("A positive target major is required.");
  }
  return `docs/migration/v${targetMajor}`;
}

// application/documentation-research.ts
var UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
var SECRET_TEXT = /(?:password|passwd|token|secret|api[_-]?key)\s*[:=]|authorization\s*:\s*bearer|-----BEGIN [A-Z ]*PRIVATE KEY-----/i;
var SEMVER = /\b(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\b/g;
async function getDocumentationResearchContext(request, ports) {
  validateRequest(request);
  const run = await loadRun(request, ports);
  requireResearchEligible(run);
  const stored = await ports.artifacts.readResearch(
    request.projectRoot,
    request.runId
  );
  const researchHash = stored === null ? null : await validateStoredResearch(stored, run, ports);
  return {
    schemaVersion: 1,
    mode: "research",
    runId: run.state.runId,
    sourceMajor: run.state.sourceMajor,
    targetMajor: run.state.targetMajor,
    planHash: run.discoveryPlan.planHash,
    dependencies: run.discoveryPlan.packages.map((item) => ({
      name: item.name,
      currentVersion: item.sourceVersion,
      targetVersion: item.targetVersion,
      reason: item.reason
    })),
    evidence: {
      status: run.state.status,
      stage: run.state.stage,
      completedOperations: run.checkpoints.filter(
        (checkpoint) => checkpoint.phase === "after" || checkpoint.phase === "skipped"
      ).map((checkpoint) => checkpoint.operationId),
      configuredChecks: run.discoveryPlan.checks.filter((check) => check.status === "configured").map((check) => check.id),
      events: run.events.map(({ sequence, type, stage, status }) => ({
        sequence,
        type,
        stage,
        status
      }))
    },
    questions: [
      `Which official breaking changes apply from Angular ${run.state.sourceMajor} to ${run.state.targetMajor}?`,
      "Which planned dependency changes require project-specific migration work?",
      "Which material questions remain unresolved after reviewing the authorized evidence?"
    ],
    submissionPath: `.angular-migration/documentation-inbox/${run.state.runId}.research.json`,
    researchHash
  };
}
async function recordDocumentationResearch(request, ports) {
  validateRequest(request);
  return withProjectLock(request.projectRoot, ports, async () => {
    const run = await loadRun(request, ports);
    requireResearchEligible(run);
    const submission = validateResearchSubmission(
      await ports.artifacts.readResearchSubmission(
        request.projectRoot,
        request.runId
      ),
      run
    );
    const researchHash = await ports.hasher.hash(submission);
    requireHash(researchHash, "documentation_research_hash_invalid");
    const existing = await ports.artifacts.readResearch(
      request.projectRoot,
      request.runId
    );
    if (existing !== null) {
      const existingHash = await validateStoredResearch(existing, run, ports);
      if (existingHash !== researchHash) {
        throw blocked3(
          "documentation_research_already_recorded",
          "Different research is already recorded for this run."
        );
      }
    } else {
      await ports.artifacts.writeResearch(request.projectRoot, request.runId, {
        schemaVersion: 1,
        runId: run.state.runId,
        planHash: run.discoveryPlan.planHash,
        researchHash,
        submission
      });
    }
    if (!run.events.some(
      (event) => event.type === "documentation-research-recorded" && event.documentation?.researchHash === researchHash
    )) {
      const event = {
        sequence: run.events.length,
        type: "documentation-research-recorded",
        stage: run.state.stage,
        status: run.state.status,
        revision: run.state.revision,
        documentation: {
          outcome: "research-recorded",
          researchHash,
          proposalHash: null,
          filesHash: null,
          outputDirectory: null,
          expectedGitSnapshot: null
        }
      };
      await saveRun2(
        run,
        request.projectRoot,
        { events: [...run.events, event] },
        ports
      );
    }
    return {
      schemaVersion: 1,
      runId: run.state.runId,
      status: "researched",
      researchHash
    };
  });
}
async function loadRun(request, ports) {
  const value = await ports.runs.read(request.projectRoot);
  if (value === null)
    throw blocked3("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(value, ports.hasher);
  if (run.state.runId !== request.runId) {
    throw blocked3(
      "run_context_mismatch",
      "The run id does not match this project."
    );
  }
  return run;
}
function requireResearchEligible(run) {
  if (run.state.status !== "running" && run.state.status !== "verified") {
    throw blocked3(
      "documentation_research_unavailable",
      "Research requires a current running or technically verified migration."
    );
  }
}
function validateResearchSubmission(value, run) {
  if (!isRecord4(value) || !hasExactKeys(value, [
    "schemaVersion",
    "runId",
    "sourceMajor",
    "targetMajor",
    "planHash",
    "researchedAt",
    "sources",
    "findings",
    "concepts",
    "unresolved"
  ]) || value.schemaVersion !== 1 || value.runId !== run.state.runId || value.sourceMajor !== run.state.sourceMajor || value.targetMajor !== run.state.targetMajor || value.planHash !== run.discoveryPlan.planHash || !isTimestamp(value.researchedAt) || !Array.isArray(value.sources) || value.sources.length === 0 || value.sources.length > 100 || !Array.isArray(value.findings) || value.findings.length > 200 || !Array.isArray(value.concepts) || value.concepts.length > 100 || !Array.isArray(value.unresolved) || value.unresolved.length > 100) {
    throw blocked3(
      "documentation_research_invalid",
      "The research submission does not match the active run contract."
    );
  }
  const sources = value.sources;
  const sourceIds = /* @__PURE__ */ new Set();
  let hasPrimary = false;
  for (const source of sources) {
    if (!isRecord4(source) || !hasExactKeys(source, [
      "id",
      "title",
      "url",
      "publisher",
      "primary",
      "accessedAt"
    ]) || typeof source.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(source.id) || sourceIds.has(source.id) || !boundedText(source.title, 160) || !boundedText(source.publisher, 160) || !isHttpsUrl(source.url) || typeof source.primary !== "boolean" || !isTimestamp(source.accessedAt)) {
      throw blocked3(
        "documentation_source_invalid",
        "A cited research source is invalid."
      );
    }
    sourceIds.add(source.id);
    hasPrimary ||= source.primary;
  }
  if (!hasPrimary) {
    throw blocked3(
      "documentation_primary_source_required",
      "Research requires at least one primary HTTPS source."
    );
  }
  const packageNames = new Set(
    run.discoveryPlan.packages.map(({ name }) => name)
  );
  const allowedVersions = knownVersions(run);
  const findingIds = /* @__PURE__ */ new Set();
  for (const finding of value.findings) {
    if (!isRecord4(finding) || !hasExactKeys(finding, [
      "id",
      "kind",
      "title",
      "area",
      "summary",
      "affectedPackages",
      "sourceIds",
      "applicability"
    ]) || typeof finding.id !== "string" || !/^F-[0-9]{1,6}$/.test(finding.id) || findingIds.has(finding.id) || !isFindingKind(finding.kind) || !boundedText(finding.title, 160) || !boundedText(finding.area, 120) || !boundedText(finding.summary, 2e3) || !containsOnlyKnownVersions(
      [finding.title, finding.summary],
      allowedVersions
    ) || !isUniqueStringArray(finding.affectedPackages, 100) || !finding.affectedPackages.every((name) => packageNames.has(name)) || !validSourceReferences(finding.sourceIds, sourceIds) || !["unknown-until-verified", "applicable", "not-applicable"].includes(
      String(finding.applicability)
    )) {
      throw blocked3(
        "documentation_finding_invalid",
        "A research finding is invalid or claims an unplanned package/version."
      );
    }
    if (finding.kind === "official-change" && !finding.sourceIds.some(
      (id) => sources.some(
        (source) => isRecord4(source) && source.id === id && source.primary === true
      )
    )) {
      throw blocked3(
        "documentation_primary_source_required",
        "Official-change findings require a primary source."
      );
    }
    findingIds.add(finding.id);
  }
  const conceptIds = /* @__PURE__ */ new Set();
  for (const concept of value.concepts) {
    if (!isRecord4(concept) || !hasExactKeys(concept, ["id", "name", "whyItMatters", "sourceIds"]) || typeof concept.id !== "string" || !/^C-[0-9]{1,6}$/.test(concept.id) || conceptIds.has(concept.id) || !boundedText(concept.name, 160) || !boundedText(concept.whyItMatters, 2e3) || !validSourceReferences(concept.sourceIds, sourceIds)) {
      throw blocked3(
        "documentation_concept_invalid",
        "A research concept is invalid."
      );
    }
    conceptIds.add(concept.id);
  }
  const unresolvedIds = /* @__PURE__ */ new Set();
  for (const item of value.unresolved) {
    if (!isRecord4(item) || !hasExactKeys(item, ["id", "question", "critical", "sourceIds"]) || typeof item.id !== "string" || !/^U-[0-9]{1,6}$/.test(item.id) || unresolvedIds.has(item.id) || !boundedText(item.question, 2e3) || typeof item.critical !== "boolean" || !Array.isArray(item.sourceIds) || item.sourceIds.some(
      (id) => typeof id !== "string" || !sourceIds.has(id)
    )) {
      throw blocked3(
        "documentation_unresolved_invalid",
        "An unresolved research item is invalid."
      );
    }
    unresolvedIds.add(item.id);
  }
  return value;
}
function validateStoredResearch(value, run, ports) {
  return validateStoredResearchAsync(value, run, ports);
}
async function validateStoredResearchAsync(value, run, ports) {
  if (!isRecord4(value) || !hasExactKeys(value, [
    "schemaVersion",
    "runId",
    "planHash",
    "researchHash",
    "submission"
  ]) || value.schemaVersion !== 1 || value.runId !== run.state.runId || value.planHash !== run.discoveryPlan.planHash || typeof value.researchHash !== "string" || !/^sha256:[a-f0-9]{64}$/.test(value.researchHash)) {
    throw blocked3(
      "documentation_record_invalid",
      "The stored research record is invalid."
    );
  }
  const submission = validateResearchSubmission(value.submission, run);
  const actualHash = await ports.hasher.hash(submission);
  if (actualHash !== value.researchHash) {
    throw blocked3(
      "documentation_record_integrity_failed",
      "The stored research digest is invalid."
    );
  }
  return value.researchHash;
}
async function saveRun2(run, projectRoot, changes, ports) {
  const { recordHash: _recordHash, ...unsigned } = run;
  await ports.runs.write(
    projectRoot,
    await sealRunRecord({ ...unsigned, ...changes }, ports.hasher)
  );
}
async function withProjectLock(projectRoot, ports, action) {
  const lease = await ports.lock.acquire(projectRoot);
  if (lease.kind !== "acquired") {
    throw blocked3(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery."
    );
  }
  let result;
  let failure;
  try {
    result = await action();
  } catch (error) {
    failure = error;
  }
  if ((await lease.release()).kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
function validateRequest(request) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || !UUID.test(request.runId)) {
    throw blocked3(
      "documentation_request_invalid",
      "A project root and valid run id are required."
    );
  }
}
function knownVersions(run) {
  return new Set(
    [
      ...run.discoveryPlan.packages.flatMap(
        ({ sourceVersion, targetVersion }) => [sourceVersion, targetVersion]
      ),
      run.discoveryPlan.runtimePlan.selected?.nodeVersion,
      run.discoveryPlan.runtimePlan.selected?.npmVersion
    ].filter((version) => typeof version === "string")
  );
}
function containsOnlyKnownVersions(texts, known) {
  return texts.every((text) => {
    if (SECRET_TEXT.test(text)) return false;
    for (const match of text.matchAll(SEMVER)) {
      if (!known.has(match[0])) return false;
    }
    return true;
  });
}
function validSourceReferences(value, sourceIds) {
  return isUniqueStringArray(value, 100) && value.length > 0 && value.every((id) => sourceIds.has(id));
}
function isUniqueStringArray(value, maximum) {
  return Array.isArray(value) && value.length <= maximum && value.every(
    (item) => typeof item === "string" && item.length > 0 && item.length <= 200
  ) && new Set(value).size === value.length;
}
function isFindingKind(value) {
  return [
    "official-change",
    "observed-change",
    "inference",
    "not-applicable"
  ].includes(String(value));
}
function isHttpsUrl(value) {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}
function isTimestamp(value) {
  return typeof value === "string" && value.length <= 64 && Number.isFinite(Date.parse(value));
}
function boundedText(value, maximum) {
  return typeof value === "string" && value.trim().length > 0 && value.length <= maximum && !SECRET_TEXT.test(value);
}
function hasExactKeys(value, expected) {
  return Object.keys(value).length === expected.length && expected.every((key) => Object.hasOwn(value, key));
}
function isRecord4(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function requireHash(value, code) {
  if (!/^sha256:[a-f0-9]{64}$/.test(value)) {
    throw blocked3(
      code,
      "The documentation evidence could not be integrity-bound."
    );
  }
}
function blocked3(code, message) {
  return new ApplicationError(code, message, "blocked");
}

// application/documentation-publish.ts
var UUID2 = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
var SECRET_TEXT2 = /(?:password|passwd|token|secret|api[_-]?key)\s*[:=]|authorization\s*:\s*bearer|-----BEGIN [A-Z ]*PRIVATE KEY-----/i;
var EXECUTABLE_TEXT = /<\s*(?:script|iframe)\b|javascript\s*:|\bon[a-z]+\s*=/i;
var SEMVER2 = /\b(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\b/g;
var MAX_DOCUMENT_BYTES = 262144;
var MAX_TOTAL_BYTES = 1048576;
async function getDocumentationPublishContext(request, ports) {
  validateRequest2(request);
  const stored = await ports.runs.read(request.projectRoot);
  if (stored === null) {
    throw blocked4("run_not_found", "No run exists for this project.");
  }
  const run = await readValidatedRunRecord(stored, ports.hasher);
  if (run.state.runId !== request.runId) {
    throw blocked4(
      "run_context_mismatch",
      "The run id does not match this project."
    );
  }
  if (run.state.status !== "verified" || run.state.stage !== "document") {
    throw blocked4(
      "publish_requires_verified",
      "Documentation publishing requires a technically verified run."
    );
  }
  const researchRecord = await ports.artifacts.readResearch(
    request.projectRoot,
    request.runId
  );
  if (!isRecord5(researchRecord)) {
    throw blocked4(
      "documentation_research_required",
      "Validated research must be recorded before publish."
    );
  }
  const researchHash = await validateStoredResearch(researchRecord, run, ports);
  if (!run.events.some(
    (event) => event.type === "documentation-research-recorded" && event.documentation?.researchHash === researchHash
  )) {
    throw blocked4(
      "documentation_research_required",
      "The run has no audit event for its research record."
    );
  }
  const outputDirectory = migrationDocumentationDirectory(
    run.state.targetMajor
  );
  const submission = await ports.artifacts.readPublishSubmission(
    request.projectRoot,
    request.runId
  );
  if (submission === null) {
    return {
      schemaVersion: 1,
      mode: "publish",
      runId: run.state.runId,
      technicalStatus: "verified",
      planHash: run.discoveryPlan.planHash,
      researchHash,
      outputDirectory,
      requiredFiles: REQUIRED_MIGRATION_DOCUMENTS.map(
        (name) => `${outputDirectory}/${name}`
      ),
      proposalHash: null,
      submissionPath: `.angular-migration/documentation-inbox/${request.runId}.publish.json`,
      recovery: false
    };
  }
  const prepared = await preparePublication(request, ports);
  return {
    schemaVersion: 1,
    mode: "publish",
    runId: prepared.run.state.runId,
    technicalStatus: "verified",
    planHash: prepared.run.discoveryPlan.planHash,
    researchHash: prepared.researchHash,
    outputDirectory: prepared.outputDirectory,
    requiredFiles: REQUIRED_MIGRATION_DOCUMENTS.map(
      (name) => `${prepared.outputDirectory}/${name}`
    ),
    proposalHash: prepared.proposalHash,
    submissionPath: `.angular-migration/documentation-inbox/${request.runId}.publish.json`,
    recovery: prepared.pending
  };
}
async function publishDocumentation(request, ports) {
  validateRequest2(request);
  if (typeof request.proposalHash !== "string" || !/^sha256:[a-f0-9]{64}$/.test(request.proposalHash) || request.confirmed !== true) {
    throw blocked4(
      request?.confirmed === true ? "documentation_publish_approval_invalid" : "confirmation_required",
      request?.confirmed === true ? "A current documentation proposal hash is required." : "Publishing documentation requires explicit confirmation."
    );
  }
  return withProjectLock2(request.projectRoot, ports, async () => {
    const prepared = await preparePublication(request, ports);
    if (prepared.proposalHash !== request.proposalHash) {
      throw blocked4(
        "documentation_publish_proposal_stale",
        "The documentation proposal changed; request confirmation again."
      );
    }
    const pendingEvent = prepared.run.events.at(-1);
    if (prepared.pending && (!pendingEvent || pendingEvent.type !== "documentation-publish-started" || !pendingEvent.documentation || pendingEvent.documentation.proposalHash !== prepared.proposalHash || pendingEvent.documentation.filesHash !== prepared.filesHash)) {
      throw blocked4(
        "documentation_publish_recovery_required",
        "An interrupted publication is bound to a different proposal."
      );
    }
    let run = prepared.run;
    if (!prepared.pending) {
      const event = {
        sequence: run.events.length,
        type: "documentation-publish-started",
        stage: "document",
        status: "verified",
        revision: run.state.revision,
        documentation: {
          outcome: "publish-started",
          researchHash: prepared.researchHash,
          proposalHash: prepared.proposalHash,
          filesHash: prepared.filesHash,
          outputDirectory: prepared.outputDirectory,
          expectedGitSnapshot: prepared.expectedGitSnapshot
        }
      };
      const checkpoint = {
        sequence: run.checkpoints.length,
        stage: "document",
        operationId: "documentation-publish",
        phase: "before",
        projectFingerprint: prepared.expectedFingerprint,
        idempotencyKey: `${run.state.runId}:document:documentation-publish:before`
      };
      run = await saveRun3(
        run,
        request.projectRoot,
        {
          events: [...run.events, event],
          checkpoints: [...run.checkpoints, checkpoint]
        },
        ports
      );
    }
    if (prepared.outputFiles === null) {
      const writtenHash = await ports.artifacts.publishFiles({
        projectRoot: request.projectRoot,
        outputDirectory: prepared.outputDirectory,
        expectedExistingFiles: null,
        expectedGitSnapshot: prepared.expectedGitSnapshot,
        nodeVersion: run.discoveryPlan.runtimePlan.selected.nodeVersion,
        files: prepared.submission.files
      });
      if (writtenHash !== prepared.filesHash) {
        throw blocked4(
          "documentation_publish_postcondition_failed",
          "The published files do not match their approved digest."
        );
      }
    }
    const outputFiles = await ports.artifacts.inspectOutput(
      request.projectRoot,
      prepared.outputDirectory
    );
    if (!sameFileSet(outputFiles, expectedOutputFiles(prepared.submission))) {
      throw blocked4(
        "documentation_publish_postcondition_failed",
        "The exact approved documentation files could not be verified."
      );
    }
    const currentFingerprint = await ports.fingerprints.readFingerprint(
      request.projectRoot
    );
    if (!isFingerprint(currentFingerprint)) {
      throw blocked4(
        "documentation_publish_postcondition_failed",
        "The project fingerprint could not be verified after publication."
      );
    }
    const publication = {
      schemaVersion: 1,
      runId: run.state.runId,
      planHash: run.discoveryPlan.planHash,
      researchHash: prepared.researchHash,
      proposalHash: prepared.proposalHash,
      filesHash: prepared.filesHash,
      outputDirectory: prepared.outputDirectory,
      files: expectedOutputFiles(prepared.submission)
    };
    const existingPublication = await ports.artifacts.readPublication(
      request.projectRoot,
      request.runId
    );
    if (existingPublication === null) {
      await ports.artifacts.writePublication(
        request.projectRoot,
        request.runId,
        publication
      );
    } else if (!samePublication(existingPublication, publication)) {
      throw blocked4(
        "documentation_record_invalid",
        "A different publication record already exists for this run."
      );
    }
    const after = {
      sequence: run.checkpoints.length,
      stage: "document",
      operationId: "documentation-publish",
      phase: "after",
      projectFingerprint: currentFingerprint,
      idempotencyKey: `${run.state.runId}:document:documentation-publish:after`
    };
    const publishedEvent = {
      sequence: run.events.length,
      type: "documentation-published",
      stage: "document",
      status: "verified",
      revision: run.state.revision,
      documentation: {
        outcome: "published",
        researchHash: prepared.researchHash,
        proposalHash: prepared.proposalHash,
        filesHash: prepared.filesHash,
        outputDirectory: prepared.outputDirectory,
        expectedGitSnapshot: prepared.expectedGitSnapshot
      }
    };
    await saveRun3(
      run,
      request.projectRoot,
      {
        events: [...run.events, publishedEvent],
        checkpoints: [...run.checkpoints, after]
      },
      ports
    );
    return {
      schemaVersion: 1,
      runId: request.runId,
      status: "published",
      technicalStatus: "verified",
      outputDirectory: prepared.outputDirectory,
      researchHash: prepared.researchHash,
      filesHash: prepared.filesHash
    };
  });
}
async function preparePublication(request, ports) {
  const run = await loadRun2(request, ports);
  if (run.state.status !== "verified" || run.state.stage !== "document") {
    throw blocked4(
      "publish_requires_verified",
      "Documentation publishing requires a technically verified run."
    );
  }
  const publication = await ports.artifacts.readPublication(
    request.projectRoot,
    request.runId
  );
  if (publication !== null && run.events.at(-1)?.type === "documentation-published") {
    throw blocked4(
      "documentation_already_published",
      "Documentation is already published for this run."
    );
  }
  const researchRecord = await ports.artifacts.readResearch(
    request.projectRoot,
    request.runId
  );
  if (!isRecord5(researchRecord)) {
    throw blocked4(
      "documentation_research_required",
      "Validated research must be recorded before publish."
    );
  }
  const researchHash = await validateStoredResearch(researchRecord, run, ports);
  if (!run.events.some(
    (event) => event.type === "documentation-research-recorded" && event.documentation?.researchHash === researchHash
  )) {
    throw blocked4(
      "documentation_research_required",
      "The run has no audit event for its research record."
    );
  }
  const submission = await validatePublishSubmission(
    await ports.artifacts.readPublishSubmission(
      request.projectRoot,
      request.runId
    ),
    run,
    researchHash,
    researchRecord,
    ports
  );
  const outputDirectory = migrationDocumentationDirectory(
    run.state.targetMajor
  );
  const expectedOutput = expectedOutputFiles(submission);
  const filesHash = await ports.hasher.hash(expectedOutput);
  requireHash2(filesHash, "documentation_hash_invalid");
  const outputFiles = await ports.artifacts.inspectOutput(
    request.projectRoot,
    outputDirectory
  );
  const pending = run.events.at(-1)?.type === "documentation-publish-started";
  const pendingGitSnapshot = pending ? run.events.at(-1)?.documentation?.expectedGitSnapshot ?? null : null;
  if (pending) {
    if (!pendingGitSnapshot || outputFiles !== null && !sameFileSet(outputFiles, expectedOutput)) {
      throw blocked4(
        "documentation_publish_recovery_required",
        "The interrupted output differs from the approved documentation set."
      );
    }
  } else if (outputFiles !== null || publication !== null) {
    throw blocked4(
      "documentation_output_exists",
      "The documentation output already exists and will not be overwritten."
    );
  }
  const expectedCheckpoint = pending ? run.checkpoints.at(-2) : run.checkpoints.at(-1);
  const beforeCheckpoint = run.checkpoints.at(-1);
  if (!expectedCheckpoint || expectedCheckpoint.stage !== "validate" || expectedCheckpoint.phase !== "after" || pending && (beforeCheckpoint?.operationId !== "documentation-publish" || beforeCheckpoint.phase !== "before")) {
    throw blocked4(
      "documentation_verification_checkpoint_invalid",
      "The verified run lacks its exact validation checkpoint."
    );
  }
  const [facts, fingerprint, gitSnapshot] = await Promise.all([
    ports.context.readProjectFacts(request.projectRoot),
    ports.fingerprints.readFingerprint(request.projectRoot),
    ports.artifacts.inspectGitSnapshot(
      request.projectRoot,
      run.discoveryPlan.runtimePlan.selected.nodeVersion
    )
  ]);
  if (facts.projectId !== run.state.projectId || facts.angularMajor !== run.state.targetMajor) {
    throw blocked4(
      "documentation_project_mismatch",
      "The project identity or Angular major changed."
    );
  }
  if (outputFiles === null && fingerprint !== expectedCheckpoint.projectFingerprint) {
    throw blocked4(
      "documentation_project_changed",
      "Project inputs changed after technical verification."
    );
  }
  const expectedGitSnapshot = pending ? pendingGitSnapshot : gitSnapshot;
  if (pending && (outputFiles === null ? !sameGitSnapshot(gitSnapshot, expectedGitSnapshot) : !onlyExpectedDocumentationChanges(
    expectedGitSnapshot,
    gitSnapshot,
    expectedOutput.map(({ path: path7 }) => path7)
  ))) {
    throw blocked4(
      "documentation_publish_recovery_required",
      "The interrupted publication has unrelated project changes."
    );
  }
  if (pending) {
    const started = run.events.at(-1);
    if (started.type !== "documentation-publish-started" || !started.documentation || started.documentation.researchHash !== researchHash || started.documentation.filesHash !== filesHash || started.documentation.outputDirectory !== outputDirectory) {
      throw blocked4(
        "documentation_publish_recovery_required",
        "The pending publish event does not match this submission."
      );
    }
  }
  const proposalHash = await ports.hasher.hash({
    schemaVersion: 1,
    runId: run.state.runId,
    planHash: run.discoveryPlan.planHash,
    researchHash,
    outputDirectory,
    expectedFingerprint: expectedCheckpoint.projectFingerprint,
    expectedExistingFiles: pending ? null : outputFiles,
    expectedGitSnapshot,
    files: submission.files,
    claims: submission.claims,
    remainingWarnings: submission.remainingWarnings
  });
  requireHash2(proposalHash, "documentation_hash_invalid");
  if (pending && run.events.at(-1)?.documentation?.proposalHash !== proposalHash) {
    throw blocked4(
      "documentation_publish_recovery_required",
      "The pending publish hash differs from the submission."
    );
  }
  return {
    run,
    submission,
    researchHash,
    filesHash,
    proposalHash,
    outputDirectory,
    expectedGitSnapshot,
    expectedFingerprint: expectedCheckpoint.projectFingerprint,
    outputFiles,
    pending
  };
}
function validatePublishSubmission(value, run, researchHash, researchValue, ports) {
  return validatePublishSubmissionAsync(
    value,
    run,
    researchHash,
    researchValue,
    ports
  );
}
async function validatePublishSubmissionAsync(value, run, researchHash, researchValue, ports) {
  const outputDirectory = migrationDocumentationDirectory(
    run.state.targetMajor
  );
  if (!isRecord5(value) || !hasExactKeys2(value, [
    "schemaVersion",
    "runId",
    "planHash",
    "researchHash",
    "outputDirectory",
    "files",
    "claims",
    "remainingWarnings"
  ]) || value.schemaVersion !== 1 || value.runId !== run.state.runId || value.planHash !== run.discoveryPlan.planHash || value.researchHash !== researchHash || value.outputDirectory !== outputDirectory || !Array.isArray(value.files) || value.files.length !== REQUIRED_MIGRATION_DOCUMENTS.length || !Array.isArray(value.claims) || value.claims.length > 200 || !Array.isArray(value.remainingWarnings) || value.remainingWarnings.length > 100) {
    throw blocked4(
      "documentation_submission_invalid",
      "Publish input does not match the approved run and research."
    );
  }
  let totalBytes = 0;
  const knownVersions2 = knownRunVersions(run);
  const files = [];
  for (let index = 0; index < REQUIRED_MIGRATION_DOCUMENTS.length; index += 1) {
    const file = value.files[index];
    const expectedPath = `${outputDirectory}/${REQUIRED_MIGRATION_DOCUMENTS[index]}`;
    if (!isRecord5(file) || !hasExactKeys2(file, ["path", "content"]) || file.path !== expectedPath || typeof file.content !== "string" || file.content.trim().length === 0 || SECRET_TEXT2.test(file.content) || EXECUTABLE_TEXT.test(file.content) || !containsOnlyKnownVersions2(file.content, knownVersions2)) {
      throw blocked4(
        "documentation_file_invalid",
        "A documentation file is invalid, sensitive, executable, or claims an unknown version."
      );
    }
    const bytes = Buffer.byteLength(file.content, "utf8");
    totalBytes += bytes;
    if (bytes > MAX_DOCUMENT_BYTES || totalBytes > MAX_TOTAL_BYTES) {
      throw blocked4(
        "documentation_submission_too_large",
        "The documentation exceeds its supported size limit."
      );
    }
    const sha2562 = await ports.contentHasher.hashText(file.content);
    if (!/^sha256:[a-f0-9]{64}$/.test(sha2562)) {
      throw blocked4(
        "documentation_file_hash_invalid",
        "A documentation file could not be integrity-bound."
      );
    }
    files.push({ path: file.path, content: file.content, sha256: sha2562 });
  }
  validateInternalLinks(files);
  const research = isRecord5(researchValue) ? researchValue : {};
  const researchSubmission = isRecord5(research.submission) ? research.submission : {};
  const sources = Array.isArray(researchSubmission.sources) ? new Set(
    researchSubmission.sources.flatMap(
      (source) => isRecord5(source) && typeof source.id === "string" ? [source.id] : []
    )
  ) : /* @__PURE__ */ new Set();
  validateClaims(value.claims, run, sources);
  if (!value.remainingWarnings.every(
    (warning) => boundedText2(warning, 2e3)
  )) {
    throw blocked4(
      "documentation_warning_invalid",
      "A remaining warning is invalid or sensitive."
    );
  }
  return value;
}
function validateClaims(value, run, sourceIds) {
  const ids = /* @__PURE__ */ new Set();
  const checkIds = /* @__PURE__ */ new Set([
    ...run.discoveryPlan.checks.map(({ id }) => id),
    ...run.checkpoints.map(({ operationId }) => operationId)
  ]);
  const eventIds = new Set(run.events.map(({ sequence }) => String(sequence)));
  const repairIds = new Set(
    run.events.flatMap(
      (event) => event.repair ? [event.repair.fingerprint] : []
    )
  );
  for (const claim of value) {
    if (!isRecord5(claim) || !hasExactKeys2(claim, ["id", "kind", "document", "evidence"]) || typeof claim.id !== "string" || !/^D-[0-9]{1,6}$/.test(claim.id) || ids.has(claim.id) || !isFindingKind2(claim.kind) || typeof claim.document !== "string" || !REQUIRED_MIGRATION_DOCUMENTS.includes(
      claim.document
    ) || !Array.isArray(claim.evidence) || claim.evidence.length === 0 || claim.evidence.length > 20 || new Set(claim.evidence).size !== claim.evidence.length) {
      throw blocked4(
        "documentation_claim_invalid",
        "A documentation claim is malformed or unbound."
      );
    }
    const evidence = claim.evidence;
    const references = evidence.map(
      (item) => parseEvidence(item, run, sourceIds, checkIds, eventIds, repairIds)
    );
    if (references.some((valid2) => !valid2)) {
      throw blocked4(
        "documentation_evidence_mismatch",
        "A documentation claim cites evidence absent from this run."
      );
    }
    const hasSource = evidence.some((item) => item.startsWith("source:"));
    const hasObserved = evidence.some(
      (item) => /^(?:event|check|repair):/.test(item) || item === "result:verified"
    );
    if (claim.kind === "official-change" && !hasSource || claim.kind === "observed-change" && !hasObserved || ["inference", "not-applicable"].includes(String(claim.kind)) && !hasSource) {
      throw blocked4(
        "documentation_evidence_mismatch",
        "A claim kind requires a matching evidence category."
      );
    }
    ids.add(claim.id);
  }
}
function parseEvidence(value, run, sourceIds, checkIds, eventIds, repairIds) {
  const separator = value.indexOf(":");
  if (separator < 1 || value.length > 256 || /\s/.test(value)) return false;
  const kind = value.slice(0, separator);
  const id = value.slice(separator + 1);
  if (!id) return false;
  switch (kind) {
    case "source":
      return sourceIds.has(id);
    case "event":
      return eventIds.has(id);
    case "check":
      return checkIds.has(id);
    case "repair":
      return repairIds.has(id);
    case "result":
      return id === "verified" && run.state.status === "verified";
    default:
      return false;
  }
}
function validateInternalLinks(files) {
  const contents = new Map(
    files.map((file) => [
      file.path.slice(file.path.lastIndexOf("/") + 1),
      file.content
    ])
  );
  const anchors = /* @__PURE__ */ new Map();
  for (const [name, content] of contents) {
    anchors.set(
      name,
      new Set(
        [...content.matchAll(/^#{1,6}\s+(.+?)\s*#*\s*$/gm)].map(
          (match) => slug(match[1])
        )
      )
    );
  }
  for (const [name, content] of contents) {
    for (const match of content.matchAll(
      /!?\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)/g
    )) {
      const target = match[1];
      if (/^https?:\/\//i.test(target)) {
        if (!isHttpsUrl2(target))
          throw blocked4(
            "documentation_link_invalid",
            "Only credential-free HTTPS external links are allowed."
          );
        continue;
      }
      if (target.startsWith("/") || target.includes("\\")) {
        throw blocked4(
          "documentation_link_invalid",
          "An internal documentation link escapes the output directory."
        );
      }
      let decoded;
      try {
        decoded = decodeURIComponent(target);
      } catch {
        throw blocked4(
          "documentation_link_invalid",
          "An internal documentation link is malformed."
        );
      }
      const [relative, anchor] = decoded.split("#", 2);
      const destination = relative || name;
      if (destination.split("/").includes("..") || destination.includes(":") || !contents.has(destination)) {
        throw blocked4(
          "documentation_link_broken",
          "A documentation link points outside or to a missing file."
        );
      }
      if (anchor && !anchors.get(destination)?.has(anchor.toLowerCase())) {
        throw blocked4(
          "documentation_link_broken",
          "A documentation link points to a missing heading."
        );
      }
    }
  }
}
async function loadRun2(request, ports) {
  const stored = await ports.runs.read(request.projectRoot);
  if (stored === null)
    throw blocked4("run_not_found", "No run exists for this project.");
  const run = await readValidatedRunRecord(stored, ports.hasher);
  if (run.state.runId !== request.runId)
    throw blocked4(
      "run_context_mismatch",
      "The run id does not match this project."
    );
  return run;
}
async function saveRun3(run, projectRoot, changes, ports) {
  const { recordHash: _recordHash, ...unsigned } = run;
  const updated = await sealRunRecord(
    { ...unsigned, ...changes },
    ports.hasher
  );
  await ports.runs.write(projectRoot, updated);
  return updated;
}
async function withProjectLock2(projectRoot, ports, action) {
  const lease = await ports.lock.acquire(projectRoot);
  if (lease.kind !== "acquired") {
    throw blocked4(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery."
    );
  }
  let result;
  let failure;
  try {
    result = await action();
  } catch (error) {
    failure = error;
  }
  if ((await lease.release()).kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
function expectedOutputFiles(submission) {
  return submission.files.map(({ path: path7, sha256: sha2562 }) => ({ path: path7, sha256: sha2562 })).sort((left, right) => left.path.localeCompare(right.path));
}
function sameFileSet(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}
function sameGitSnapshot(left, right) {
  return left.head === right.head && JSON.stringify(left.changes) === JSON.stringify(right.changes);
}
function onlyExpectedDocumentationChanges(before, after, expectedFiles) {
  if (before.head !== after.head) return false;
  const previous = new Map(
    before.changes.map((change) => [change.path, change.status])
  );
  const current = new Map(
    after.changes.map((change) => [change.path, change.status])
  );
  if ([...previous].some(([file, status]) => current.get(file) !== status))
    return false;
  const added = [...current.keys()].filter((file) => !previous.has(file)).sort();
  return JSON.stringify(added) === JSON.stringify([...expectedFiles].sort()) && added.every((file) => current.get(file) === "??");
}
function samePublication(left, right) {
  return Boolean(
    isRecord5(left) && left.schemaVersion === 1 && left.runId === right.runId && left.planHash === right.planHash && left.researchHash === right.researchHash && left.proposalHash === right.proposalHash && left.filesHash === right.filesHash && left.outputDirectory === right.outputDirectory && JSON.stringify(left.files) === JSON.stringify(right.files)
  );
}
function knownRunVersions(run) {
  return new Set(
    [
      ...run.discoveryPlan.packages.flatMap(
        ({ sourceVersion, targetVersion }) => [sourceVersion, targetVersion]
      ),
      run.discoveryPlan.runtimePlan.selected?.nodeVersion,
      run.discoveryPlan.runtimePlan.selected?.npmVersion
    ].filter((version) => typeof version === "string")
  );
}
function containsOnlyKnownVersions2(text, known) {
  for (const match of text.matchAll(SEMVER2))
    if (!known.has(match[0])) return false;
  return true;
}
function isFindingKind2(value) {
  return [
    "official-change",
    "observed-change",
    "inference",
    "not-applicable"
  ].includes(String(value));
}
function isHttpsUrl2(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}
function slug(value) {
  return value.toLowerCase().replace(/[`*_~]/g, "").replace(/[^a-z0-9 -]/g, "").trim().replace(/\s+/g, "-");
}
function boundedText2(value, maximum) {
  return typeof value === "string" && value.trim().length > 0 && value.length <= maximum && !SECRET_TEXT2.test(value);
}
function hasExactKeys2(value, expected) {
  return Object.keys(value).length === expected.length && expected.every((key) => Object.hasOwn(value, key));
}
function isRecord5(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function isFingerprint(value) {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
}
function requireHash2(value, code) {
  if (!isFingerprint(value))
    throw blocked4(
      code,
      "The documentation proposal could not be integrity-bound."
    );
}
function validateRequest2(request) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || !UUID2.test(request.runId)) {
    throw blocked4(
      "documentation_request_invalid",
      "A project root and valid run id are required."
    );
  }
}
function blocked4(code, message) {
  return new ApplicationError(code, message, "blocked");
}

// application/inspect-project.ts
async function inspectProject(request, ports) {
  const facts = await ports.facts.readProjectFacts(request.projectRoot);
  return {
    schemaVersion: 1,
    projectId: facts.projectId,
    angularMajor: facts.angularMajor
  };
}

// application/repair-run.ts
var MAX_REPAIR_FILES = 20;
var MAX_REPAIR_BYTES = 1048576;
var MAX_REPAIR_ATTEMPTS = 3;
var MAX_RUN_REPAIR_ATTEMPTS = 5;
var FORBIDDEN_PATHS = [
  ".git/**",
  ".angular-migration/**",
  "package.json",
  "package-lock.json",
  "npm-shrinkwrap.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "scripts/**",
  "hooks.json",
  "agents/**",
  "docs/**",
  "**/.npmrc",
  "**/.env*",
  "**/*.pem",
  "**/*.key",
  "**/*.pfx",
  "**/*.p12"
];
async function getRepairContext(request, ports) {
  const record = await readActiveRepairRecord(request, ports);
  return createContext(record, request.projectRoot, ports);
}
async function recordRepair(request, ports) {
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery.",
      "blocked"
    );
  }
  let result;
  let failure;
  let patchLease;
  try {
    let record = await readActiveRepairRecord(request, ports);
    const context = await createContext(record, request.projectRoot, ports);
    const submission = validateSubmission(request.submission, context);
    const submissionHash = await ports.hasher.hash(request.submission);
    if (record.events.some(
      (event) => event.repair?.submissionHash === submissionHash
    )) {
      throw blocked5(
        "repair_submission_replayed",
        "This repair submission was already processed."
      );
    }
    patchLease = await ports.patches.apply(
      request.projectRoot,
      submission.files
    );
    const operation = repairOperation(record, context.failedCheck);
    let verificationPassed = false;
    try {
      verificationPassed = (await ports.operations.execute(request.projectRoot, operation)).outcome === "passed";
    } catch {
      verificationPassed = false;
    }
    const afterFingerprint = verificationPassed ? await ports.fingerprints.readFingerprint(request.projectRoot).catch(() => "") : "";
    if (!verificationPassed || !/^sha256:[a-f0-9]{64}$/.test(afterFingerprint)) {
      await patchLease.rollback();
      patchLease = void 0;
      record = await appendRepairEvent(
        record,
        request.projectRoot,
        {
          attempt: context.attempt,
          fingerprint: context.fingerprint,
          submissionHash,
          changedPaths: submission.files.map(({ path: file }) => file),
          outcome: "rejected"
        },
        ports
      );
      throw blocked5(
        "repair_verification_failed",
        "The controller's original validation gate did not pass after repair."
      );
    }
    const transition = decideRunTransition(
      record.state,
      { status: "running", stage: "validate" },
      "repair-verified"
    );
    if (transition.outcome !== "allowed") {
      await patchLease.rollback();
      patchLease = void 0;
      throw blocked5(
        "repair_transition_rejected",
        "The verified repair cannot resume the current run state."
      );
    }
    const latest = record.checkpoints.at(-1);
    const checkpoint = {
      sequence: record.checkpoints.length,
      stage: "validate",
      operationId: latest.operationId,
      phase: "after",
      projectFingerprint: afterFingerprint,
      idempotencyKey: `${record.state.runId}:validate:${latest.operationId}:after`
    };
    const { recordHash: _oldHash, ...unsigned } = record;
    const updated = await sealRunRecord(
      {
        ...unsigned,
        state: transition.value,
        diagnostic: null,
        checkpoints: [...record.checkpoints, checkpoint],
        events: [
          ...record.events,
          {
            sequence: record.events.length,
            type: "repair-accepted",
            stage: "validate",
            status: "running",
            revision: transition.value.revision,
            repair: {
              attempt: context.attempt,
              fingerprint: context.fingerprint,
              submissionHash,
              changedPaths: submission.files.map(({ path: file }) => file),
              outcome: "accepted"
            }
          }
        ]
      },
      ports.hasher
    );
    await ports.records.write(request.projectRoot, updated);
    patchLease = void 0;
    result = {
      runId: request.runId,
      status: "running",
      stage: "validate",
      attempt: context.attempt,
      changedPaths: submission.files.map(({ path: file }) => file),
      verification: "passed"
    };
  } catch (error) {
    if (patchLease) {
      try {
        await patchLease.rollback();
      } catch {
        failure = blocked5(
          "repair_rollback_unconfirmed",
          "Repair rollback could not be verified; human recovery is required."
        );
      }
    }
    failure ??= error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
async function readActiveRepairRecord(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || request.runId.trim().length === 0) {
    throw blocked5(
      "repair_request_invalid",
      "A project root and run id are required."
    );
  }
  const stored = await ports.records.read(request.projectRoot);
  if (stored === null)
    throw blocked5("run_not_found", "No run exists for this project.");
  const record = await readValidatedRunRecord(stored, ports.hasher);
  const latest = record.checkpoints.at(-1);
  if (record.state.runId !== request.runId || record.state.status !== "needs-repair" || record.state.stage !== "validate" || record.diagnostic?.code !== "process_nonzero_exit" || latest?.stage !== "validate" || latest.phase !== "before" || !latest.operationId.startsWith("validate-")) {
    throw blocked5(
      "repair_context_unavailable",
      "Repair requires a blocked configured validation check in the active run."
    );
  }
  return record;
}
async function createContext(record, projectRoot, ports) {
  const latest = record.checkpoints.at(-1);
  const fingerprint = await ports.fingerprints.readFingerprint(projectRoot);
  if (fingerprint !== latest.projectFingerprint) {
    throw blocked5(
      "repair_fingerprint_stale",
      "Project inputs changed after the failed validation check."
    );
  }
  const attempts = record.events.filter((event) => event.repair).length;
  const fingerprintAttempts = record.events.filter(
    (event) => event.repair?.fingerprint === fingerprint
  ).length;
  if (fingerprintAttempts >= MAX_REPAIR_ATTEMPTS || attempts >= MAX_RUN_REPAIR_ATTEMPTS) {
    throw blocked5(
      "repair_attempts_exhausted",
      "The repair attempt limit for this run has been reached."
    );
  }
  const checkId = latest.operationId.slice("validate-".length);
  const check = record.discoveryPlan.checks.find(
    (item) => item.id === checkId && item.status === "configured"
  );
  if (!check || check.executable !== "npm") {
    throw blocked5(
      "repair_scope_unknown",
      "The failed check has no safe repair contract."
    );
  }
  return {
    schemaVersion: 1,
    runId: record.state.runId,
    projectId: record.state.projectId,
    fingerprint,
    stage: "validate",
    failedCheck: checkId,
    attempt: fingerprintAttempts + 1,
    maxAttempts: MAX_REPAIR_ATTEMPTS,
    maxRunAttempts: MAX_RUN_REPAIR_ATTEMPTS,
    allowedPaths: ["src/**/*"],
    forbiddenPaths: FORBIDDEN_PATHS,
    diagnostic: record.diagnostic,
    submissionPath: `.angular-migration/repair-inbox/${record.state.runId}.json`
  };
}
function validateSubmission(value, context) {
  if (!isRecord6(value) || !hasExactKeys3(value, [
    "schemaVersion",
    "runId",
    "fingerprint",
    "attempt",
    "rootCause",
    "changes",
    "evidence",
    "unresolvedWarnings"
  ])) {
    throw blocked5(
      "repair_submission_invalid",
      "Repair submission shape is invalid."
    );
  }
  if (value.schemaVersion !== 1 || value.runId !== context.runId || value.fingerprint !== context.fingerprint || value.attempt !== context.attempt) {
    throw blocked5(
      "repair_submission_stale",
      "Repair submission does not match the issued context."
    );
  }
  if (typeof value.rootCause !== "string" || !value.rootCause.trim() || value.rootCause.length > 4e3 || !Array.isArray(value.changes) || value.changes.length === 0 || value.changes.length > MAX_REPAIR_FILES || !Array.isArray(value.evidence) || value.evidence.length === 0 || !value.evidence.every(isRepairEvidence) || !value.evidence.every((item) => item.reference === "run-diagnostic") || !Array.isArray(value.unresolvedWarnings) || !value.unresolvedWarnings.every(
    (item) => typeof item === "string" && item.trim().length > 0 && item.length <= 1e3
  )) {
    throw blocked5(
      "repair_submission_invalid",
      "Repair submission fields are invalid."
    );
  }
  let totalBytes = 0;
  const seen = /* @__PURE__ */ new Set();
  const files = [];
  for (const change of value.changes) {
    if (!isRecord6(change) || !hasExactKeys3(change, ["path", "summary", "reason", "content"]) || typeof change.path !== "string" || !/^src\/[A-Za-z0-9._/-]+$/.test(change.path) || change.path.split("/").includes("..") || /[\\:]|\0/.test(change.path) || seen.has(change.path) || typeof change.summary !== "string" || !change.summary.trim() || change.summary.length > 1e3 || typeof change.reason !== "string" || !change.reason.trim() || change.reason.length > 1e3 || typeof change.content !== "string" || containsSensitiveText(change.content)) {
      throw blocked5(
        "repair_submission_invalid",
        "Repair contains an invalid or unauthorized file change."
      );
    }
    seen.add(change.path);
    totalBytes += Buffer.byteLength(change.content, "utf8");
    if (totalBytes > MAX_REPAIR_BYTES) {
      throw blocked5(
        "repair_submission_too_large",
        "Repair submission exceeds the size limit."
      );
    }
    files.push({ path: change.path, content: change.content });
  }
  return { files };
}
function repairOperation(record, checkId) {
  const check = record.discoveryPlan.checks.find(
    (item) => item.id === checkId && item.status === "configured"
  );
  const nodeVersion = record.discoveryPlan.runtimePlan.selected?.nodeVersion;
  if (!check || check.executable !== "npm" || check.arguments.length !== 2 || check.arguments[0] !== "run" || !/^[a-zA-Z0-9:_-]+$/.test(check.arguments[1]) || !nodeVersion) {
    throw blocked5(
      "repair_gate_invalid",
      "The original validation gate cannot be reconstructed safely."
    );
  }
  return {
    id: `validate-${checkId}`,
    kind: "process",
    stage: "validate",
    executable: "npm",
    arguments: check.arguments,
    nodeVersion,
    timeoutMs: 6e5,
    postcondition: "exit-zero",
    packages: []
  };
}
async function appendRepairEvent(record, projectRoot, repair, ports) {
  const { recordHash: _oldHash, ...unsigned } = record;
  const updated = await sealRunRecord(
    {
      ...unsigned,
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "repair-rejected",
          stage: "validate",
          status: "needs-repair",
          revision: record.state.revision,
          repair
        }
      ]
    },
    ports.hasher
  );
  await ports.records.write(projectRoot, updated);
  return updated;
}
function isRepairEvidence(value) {
  return Boolean(
    isRecord6(value) && hasExactKeys3(value, ["reference", "claim"]) && typeof value.reference === "string" && value.reference.length > 0 && typeof value.claim === "string" && value.claim.trim().length > 0 && value.claim.length <= 1e3
  );
}
function containsSensitiveText(value) {
  return /(?:authorization\s*:\s*bearer\s+|(?:password|token|secret)\s*[=:]\s*|https?:\/\/[^/@\s]+:[^/@\s]+@)/i.test(
    value
  );
}
function hasExactKeys3(value, keys) {
  return Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
}
function isRecord6(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function blocked5(code, message) {
  return new ApplicationError(code, message, "blocked");
}

// application/run-project.ts
async function runProject(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0 || typeof request.runId !== "string" || request.runId.trim().length === 0) {
    throw new ApplicationError(
      "run_request_invalid",
      "A project root and run id are required."
    );
  }
  const lease = await ports.lock.acquire(request.projectRoot);
  if (lease.kind !== "acquired") {
    throw new ApplicationError(
      lease.kind === "contended" ? "project_busy" : "project_recovery_required",
      lease.kind === "contended" ? "Another controller operation owns this project." : "Project lock ownership requires recovery."
    );
  }
  let result;
  let failure;
  try {
    const stored = await ports.records.read(request.projectRoot);
    if (stored === null) {
      throw new ApplicationError(
        "run_not_found",
        "No run exists for this project."
      );
    }
    let record = await readValidatedRunRecord(stored, ports.hasher);
    if (record.state.runId !== request.runId) {
      throw new ApplicationError(
        "run_context_mismatch",
        "The requested run id does not match the active run."
      );
    }
    if (record.state.status !== "running") {
      result = record;
    } else {
      record = await verifyCurrentRunContext(
        record,
        request.projectRoot,
        ports
      );
      if (record.state.status !== "running") {
        result = record;
      } else {
        result = await executeStages(record, request.projectRoot, ports);
      }
    }
  } catch (error) {
    failure = error;
  }
  const release = await lease.release();
  if (release.kind !== "released") {
    throw new ApplicationError(
      "project_lock_release_unconfirmed",
      "The operation finished but project lock ownership could not be confirmed."
    );
  }
  if (failure !== void 0) throw failure;
  return result;
}
async function verifyCurrentRunContext(record, projectRoot, ports) {
  const latest = record.checkpoints.at(-1);
  if (latest?.phase === "before") {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "operation_outcome_ambiguous",
      message: "An operation has no verified after-checkpoint; automatic retry is unsafe."
    });
  }
  let facts;
  let fingerprint;
  try {
    [facts, fingerprint] = await Promise.all([
      ports.facts.readProjectFacts(projectRoot),
      ports.fingerprints.readFingerprint(projectRoot)
    ]);
  } catch {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_state_unavailable",
      message: "Current project state could not be verified safely."
    });
  }
  if (facts.projectId !== record.state.projectId) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_identity_changed",
      message: "The project identity differs from the one bound to this run."
    });
  }
  const expectedMajor = record.state.stage === "update-angular" && latest?.stage === "update-angular" && latest.phase === "after" ? record.state.targetMajor : [
    "update-dependencies",
    "install",
    "validate",
    "document",
    "done"
  ].includes(record.state.stage) ? record.state.targetMajor : record.state.sourceMajor;
  if (facts.angularMajor !== expectedMajor) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_major_unexpected",
      message: "The project Angular major does not match the last verified stage."
    });
  }
  const expectedFingerprint = latest?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
  if (!isSha2562(fingerprint) || fingerprint !== expectedFingerprint) {
    return finishRun(record, projectRoot, ports, "blocked", {
      code: "project_fingerprint_changed",
      message: "Project inputs changed outside the last verified checkpoint."
    });
  }
  return record;
}
async function executeStages(initial, projectRoot, ports) {
  let record = initial;
  while (record.state.status === "running") {
    const stage = record.state.stage;
    const operations = buildOperations(record, stage);
    const latest = record.checkpoints.at(-1);
    let startAt = 0;
    if (latest?.stage === stage) {
      if (latest.phase === "before") {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "operation_outcome_ambiguous",
          message: "An operation has no verified after-checkpoint; automatic retry is unsafe."
        });
      }
      const completedIndex = operations.findIndex(
        (operation) => operation.id === latest.operationId
      );
      if (completedIndex < 0) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "checkpoint_operation_invalid",
          message: "The last checkpoint does not match the current stage plan."
        });
      }
      startAt = completedIndex + 1;
    }
    for (let index = startAt; index < operations.length; index += 1) {
      const operation = operations[index];
      let beforeFingerprint;
      try {
        beforeFingerprint = await ports.fingerprints.readFingerprint(projectRoot);
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "project_state_unavailable",
          message: "Current project state could not be verified before an operation."
        });
      }
      const prior = record.checkpoints.at(-1);
      const expected = prior?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
      if (beforeFingerprint !== expected) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "project_fingerprint_changed",
          message: "Project inputs changed outside the last verified checkpoint."
        });
      }
      record = await saveCheckpoint(record, projectRoot, ports, {
        operation,
        phase: "before",
        fingerprint: beforeFingerprint,
        startStage: !record.events.some(
          (event) => event.type === "stage-started" && event.stage === stage
        )
      });
      let operationResult;
      try {
        operationResult = await ports.operations.execute(
          projectRoot,
          operation
        );
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "operation_outcome_unconfirmed",
          message: "An operation failed before its postcondition could be confirmed."
        });
      }
      if (operationResult.outcome !== "passed") {
        if (stage === "validate" && operation.id.startsWith("validate-") && operationResult.outcome === "blocked" && operationResult.diagnostic.code === "process_nonzero_exit") {
          return finishRun(
            record,
            projectRoot,
            ports,
            "needs-repair",
            operationResult.diagnostic
          );
        }
        return finishRun(
          record,
          projectRoot,
          ports,
          operationResult.outcome,
          operationResult.diagnostic
        );
      }
      let afterFingerprint;
      try {
        afterFingerprint = await ports.fingerprints.readFingerprint(projectRoot);
      } catch {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "postcondition_unconfirmed",
          message: "The operation passed but its resulting project state is unavailable."
        });
      }
      if (!isSha2562(afterFingerprint)) {
        return finishRun(record, projectRoot, ports, "blocked", {
          code: "postcondition_invalid",
          message: "The operation returned an invalid project fingerprint."
        });
      }
      record = await saveCheckpoint(record, projectRoot, ports, {
        operation,
        phase: "after",
        fingerprint: afterFingerprint,
        startStage: false
      });
    }
    record = await completeStage(record, stage, projectRoot, ports);
  }
  return record;
}
function buildOperations(record, stage) {
  const nodeVersion = record.discoveryPlan.runtimePlan.selected?.nodeVersion;
  if (!nodeVersion || !parseExactSemverVersion(nodeVersion)) {
    throw new ApplicationError(
      "planned_runtime_invalid",
      "The run does not contain an exact planned Node runtime."
    );
  }
  const packages = record.discoveryPlan.packages.map(
    ({ name, targetVersion }) => ({
      name,
      targetVersion
    })
  );
  const process2 = (id, executable, arguments_, timeoutMs, postcondition, expectedPackages = []) => ({
    id,
    kind: "process",
    stage,
    executable,
    arguments: arguments_,
    nodeVersion,
    timeoutMs,
    postcondition,
    packages: expectedPackages
  });
  const packagePin = () => ({
    id: "pin-target-packages",
    kind: "pin-packages",
    stage,
    executable: null,
    arguments: [],
    nodeVersion,
    timeoutMs: 3e4,
    postcondition: "target-packages-declared",
    packages
  });
  switch (stage) {
    case "baseline":
      return [
        process2(
          "baseline-install",
          "npm",
          ["ci"],
          6e5,
          "package-metadata-stable"
        ),
        process2(
          "baseline-dependency-tree",
          "npm",
          ["ls", "--all"],
          3e5,
          "dependency-tree"
        ),
        ...configuredCheckOperations(record, stage, process2)
      ];
    case "resolve":
      return [
        {
          id: "verify-discovery-plan",
          kind: "verify-plan",
          stage,
          executable: null,
          arguments: [],
          nodeVersion,
          timeoutMs: 1,
          postcondition: "verify-plan",
          packages
        }
      ];
    case "update-angular": {
      const core = packages.find((item) => item.name === "@angular/core");
      const cli = packages.find((item) => item.name === "@angular/cli");
      if (!core || !cli) {
        throw new ApplicationError(
          "angular_cli_metadata_missing",
          "The immutable discovery plan must include exact Angular core and CLI versions."
        );
      }
      return [
        process2(
          "angular-core-cli-update",
          "npm",
          [
            "exec",
            "--",
            "ng",
            "update",
            `@angular/core@${core.targetVersion}`,
            `@angular/cli@${cli.targetVersion}`
          ],
          6e5,
          "target-packages-locked",
          [core, cli]
        )
      ];
    }
    case "update-dependencies":
      return [
        packagePin(),
        process2(
          "update-lockfile",
          "npm",
          ["install", "--package-lock-only", "--ignore-scripts"],
          6e5,
          "target-packages-locked",
          packages
        )
      ];
    case "install":
      return [
        process2(
          "install-clean",
          "npm",
          ["ci"],
          6e5,
          "package-metadata-stable"
        ),
        process2(
          "install-dependency-tree",
          "npm",
          ["ls", "--all"],
          3e5,
          "dependency-tree"
        )
      ];
    case "validate":
      return configuredCheckOperations(record, stage, process2);
    default:
      throw new ApplicationError(
        "run_stage_invalid",
        "The current run stage cannot execute in this lifecycle step."
      );
  }
}
async function saveCheckpoint(record, projectRoot, ports, input) {
  const checkpoint = {
    sequence: record.checkpoints.length,
    stage: input.operation.stage,
    operationId: input.operation.id,
    phase: input.phase,
    projectFingerprint: input.fingerprint,
    idempotencyKey: `${record.state.runId}:${input.operation.stage}:${input.operation.id}:${input.phase}`
  };
  const events = input.startStage ? [
    ...record.events,
    {
      sequence: record.events.length,
      type: "stage-started",
      stage: input.operation.stage,
      status: record.state.status,
      revision: record.state.revision
    }
  ] : record.events;
  return persist(
    {
      ...record,
      events,
      checkpoints: [...record.checkpoints, checkpoint]
    },
    projectRoot,
    ports
  );
}
async function completeStage(record, stage, projectRoot, ports) {
  const transition = stage === "validate" ? decideRunTransition(record.state, {
    status: "verified",
    stage: "document"
  }) : decideRunTransition(record.state, {
    status: "running",
    stage: nextStage(stage)
  });
  if (transition.outcome !== "allowed") {
    throw new ApplicationError(
      "run_transition_rejected",
      "The lifecycle stage transition was rejected by the domain contract."
    );
  }
  return persist(
    {
      ...record,
      state: transition.value,
      diagnostic: null,
      events: [
        ...record.events,
        {
          sequence: record.events.length,
          type: "stage-completed",
          stage,
          status: transition.value.status,
          revision: transition.value.revision
        }
      ]
    },
    projectRoot,
    ports
  );
}
async function finishRun(record, projectRoot, ports, status, diagnostic) {
  if (record.state.status !== "running") return record;
  const transition = decideRunTransition(record.state, {
    status,
    stage: record.state.stage
  });
  if (transition.outcome !== "allowed") {
    throw new ApplicationError(
      "run_transition_rejected",
      "The lifecycle failure transition was rejected by the domain contract."
    );
  }
  const event = {
    sequence: record.events.length,
    type: status === "blocked" ? "stage-blocked" : status === "failed" ? "stage-failed" : "stage-needs-repair",
    stage: record.state.stage,
    status,
    revision: transition.value.revision
  };
  return persist(
    {
      ...record,
      state: transition.value,
      diagnostic,
      events: [...record.events, event]
    },
    projectRoot,
    ports
  );
}
async function persist(content, projectRoot, ports) {
  const { recordHash: _previousHash, ...unsigned } = content;
  const record = await sealRunRecord(unsigned, ports.hasher);
  await ports.records.write(projectRoot, record);
  return record;
}
function nextStage(stage) {
  const next = {
    baseline: "resolve",
    resolve: "update-angular",
    "update-angular": "update-dependencies",
    "update-dependencies": "install",
    install: "validate"
  };
  const result = next[stage];
  if (!result) {
    throw new ApplicationError(
      "run_stage_invalid",
      "No next technical stage exists."
    );
  }
  return result;
}
function isSha2562(value) {
  return /^sha256:[a-f0-9]{64}$/.test(value);
}
function configuredCheckOperations(record, stage, process2) {
  return record.discoveryPlan.checks.filter(
    (check) => check.status === "configured" && !["install", "dependency-tree"].includes(check.id)
  ).map((check) => {
    if (check.executable !== "npm" || check.arguments.length !== 2 || check.arguments[0] !== "run" || !/^[a-zA-Z0-9:_-]+$/.test(check.arguments[1])) {
      throw new ApplicationError(
        "project_check_invalid",
        "A configured project check is outside the supported npm script contract."
      );
    }
    return process2(
      `${stage === "baseline" ? "baseline" : "validate"}-${check.id}`,
      "npm",
      check.arguments,
      6e5,
      "exit-zero"
    );
  });
}

// application/status-run.ts
async function getRunStatus(request, ports) {
  if (!request || typeof request.projectRoot !== "string" || request.projectRoot.trim().length === 0) {
    throw new ApplicationError(
      "status_request_invalid",
      "A project root is required to read run status."
    );
  }
  const value = await ports.records.read(request.projectRoot);
  if (value === null) {
    throw new ApplicationError(
      "run_not_found",
      "No run exists for this project."
    );
  }
  const record = await readValidatedRunRecord(value, ports.hasher);
  const state = record.state;
  let diagnostic = null;
  let nextAction = state.status === "running" ? "run" : state.status === "verified" ? "documentation" : state.status === "completed" ? "none" : "human-intervention";
  const latest = record.checkpoints.at(-1);
  if ((state.status === "running" || state.status === "verified") && latest?.phase === "before") {
    nextAction = "human-intervention";
    diagnostic = {
      code: "operation_outcome_ambiguous",
      message: "An operation has no verified after-checkpoint."
    };
  } else if (state.status === "running" || state.status === "verified") {
    try {
      const [facts, fingerprint] = await Promise.all([
        ports.context.readProjectFacts(request.projectRoot),
        ports.context.readFingerprint(request.projectRoot)
      ]);
      const expectedMajor = expectedAngularMajor(record);
      const expectedFingerprint = latest?.projectFingerprint ?? record.discoveryPlan.inputFingerprint;
      if (facts.projectId !== state.projectId) {
        diagnostic = {
          code: "project_identity_changed",
          message: "The current project identity differs from the run."
        };
      } else if (facts.angularMajor !== expectedMajor) {
        diagnostic = {
          code: "project_major_unexpected",
          message: "The current Angular major differs from the last checkpoint."
        };
      } else if (!/^sha256:[a-f0-9]{64}$/.test(fingerprint) || fingerprint !== expectedFingerprint) {
        diagnostic = {
          code: "project_fingerprint_changed",
          message: "Project inputs changed after the last verified checkpoint."
        };
      }
    } catch {
      diagnostic = {
        code: "project_state_unavailable",
        message: "Current project state could not be verified safely."
      };
    }
    if (diagnostic) nextAction = "human-intervention";
  }
  return {
    schemaVersion: 1,
    runId: state.runId,
    status: state.status,
    stage: state.stage,
    sourceMajor: state.sourceMajor,
    targetMajor: state.targetMajor,
    revision: state.revision,
    nextAction,
    diagnostic
  };
}
function expectedAngularMajor(record) {
  return [
    "update-dependencies",
    "install",
    "validate",
    "document",
    "done"
  ].includes(record.state.stage) || record.state.stage === "update-angular" && record.checkpoints.at(-1)?.stage === "update-angular" && record.checkpoints.at(-1)?.phase === "after" ? record.state.targetMajor : record.state.sourceMajor;
}

// infrastructure/baseline-dependencies.ts
import { createHash } from "node:crypto";

// infrastructure/fnm-runtime.ts
import { spawn as spawn2 } from "node:child_process";
import path from "node:path";

// infrastructure/process-runner.ts
import {
  spawn
} from "node:child_process";
var MAX_ARGUMENTS = 256;
var MAX_ARGUMENT_LENGTH = 32768;
var MAX_ARGUMENT_BYTES = 1048576;
var MAX_ENVIRONMENT_ENTRIES = 256;
var MAX_ENVIRONMENT_BYTES = 65536;
var MAX_CAPTURED_OUTPUT_BYTES = 1048576;
var MAX_TIMEOUT_MS = 6e5;
var MAX_TERMINATION_GRACE_MS = 3e4;
async function runProcess(request, spawnProcess = spawn) {
  const invalidReason = validateRequest3(request);
  if (invalidReason)
    return emptyResult({ kind: "invalid-request", reason: invalidReason });
  const stdout = new BoundedOutput(request.maxOutputBytes);
  const stderr = new BoundedOutput(request.maxOutputBytes);
  let child;
  try {
    const options = {
      cwd: request.cwd,
      env: { ...request.env },
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    };
    child = spawnProcess(request.executable, [...request.arguments], options);
  } catch (error) {
    return emptyResult({ kind: "spawn-failed", errorCode: errorCode(error) });
  }
  return new Promise((resolve) => {
    let finished = false;
    let spawned = false;
    let timedOut = false;
    let childErrorCode;
    let timeoutTimer;
    let escalationTimer;
    let terminationTimer;
    const output = () => ({
      stdout: redactOutput(stdout.text(), request.cwd),
      stderr: redactOutput(stderr.text(), request.cwd),
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated
    });
    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeoutTimer);
      clearTimeout(escalationTimer);
      clearTimeout(terminationTimer);
      resolve({ ...output(), ...result });
    };
    child.stdout?.on("data", (chunk) => stdout.append(chunk));
    child.stderr?.on("data", (chunk) => stderr.append(chunk));
    child.once("spawn", () => {
      spawned = true;
    });
    child.once("error", (error) => {
      const code = errorCode(error);
      if (!spawned) {
        finish({ ...output(), kind: "spawn-failed", errorCode: code });
      } else {
        childErrorCode = code;
      }
    });
    child.once("close", (exitCode, signal) => {
      if (timedOut) {
        finish({ ...output(), kind: "timed-out", terminated: true });
      } else if (childErrorCode) {
        finish({
          ...output(),
          kind: "process-error",
          errorCode: childErrorCode
        });
      } else if (signal) {
        finish({ ...output(), kind: "signaled", signal });
      } else if (exitCode !== null) {
        finish({ ...output(), kind: "exited", exitCode });
      } else {
        finish({
          ...output(),
          kind: "process-error",
          errorCode: "UNKNOWN_PROCESS_OUTCOME"
        });
      }
    });
    timeoutTimer = setTimeout(() => {
      timedOut = true;
      try {
        child.kill("SIGTERM");
      } catch {
      }
      escalationTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
        }
        terminationTimer = setTimeout(() => {
          finish({ ...output(), kind: "timed-out", terminated: false });
        }, request.terminationGraceMs);
      }, request.terminationGraceMs);
    }, request.timeoutMs);
  });
}
function validateRequest3(request) {
  if (!request || typeof request !== "object") return "request-invalid";
  if (!nonEmptyString(request.executable) || !nonEmptyString(request.cwd) || request.executable.length > MAX_ARGUMENT_LENGTH || request.cwd.length > MAX_ARGUMENT_LENGTH)
    return "executable-or-cwd-invalid";
  if (request.executable.includes("\0") || request.cwd.includes("\0"))
    return "executable-or-cwd-invalid";
  if (!Array.isArray(request.arguments) || request.arguments.length > MAX_ARGUMENTS)
    return "arguments-invalid";
  if (request.arguments.some(
    (argument) => typeof argument !== "string" || argument.includes("\0") || argument.length > MAX_ARGUMENT_LENGTH
  ) || request.arguments.reduce((size, argument) => size + argument.length, 0) > MAX_ARGUMENT_BYTES) {
    return "arguments-invalid";
  }
  if (containsCredentialArguments(request.arguments))
    return "credentials-must-not-be-passed-as-arguments";
  if (!request.env || typeof request.env !== "object" || Object.keys(request.env).length > MAX_ENVIRONMENT_ENTRIES || Object.entries(request.env).reduce(
    (size, [key, value]) => size + key.length + (typeof value === "string" ? value.length : 0),
    0
  ) > MAX_ENVIRONMENT_BYTES) {
    return "environment-invalid";
  }
  if (Object.entries(request.env).some(
    ([key, value]) => !key || key.includes("=") || key.includes("\0") || typeof value !== "string" || value.includes("\0")
  )) {
    return "environment-invalid";
  }
  if (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs < 1 || request.timeoutMs > MAX_TIMEOUT_MS) {
    return "timeout-invalid";
  }
  if (!Number.isSafeInteger(request.terminationGraceMs) || request.terminationGraceMs < 1 || request.terminationGraceMs > MAX_TERMINATION_GRACE_MS) {
    return "termination-grace-invalid";
  }
  if (!Number.isSafeInteger(request.maxOutputBytes) || request.maxOutputBytes < 0 || request.maxOutputBytes > MAX_CAPTURED_OUTPUT_BYTES) {
    return "output-limit-invalid";
  }
  return void 0;
}
function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}
function containsCredentialArguments(arguments_) {
  const credentialOption = /^--?(?:_auth(?:token)?|token|password|secret|authorization|api[-_]?key)(?:=|$)/i;
  const credentialAssignment = /(?:^|[^a-z0-9])(?:_auth(?:token)?|token|password|secret|authorization|api[-_]?key)\s*[:=]/i;
  const urlCredentials = /https?:\/\/[^/@\s]+:[^/@\s]+@/i;
  return arguments_.some(
    (argument, index) => credentialAssignment.test(argument) || urlCredentials.test(argument) || /^Bearer\s+\S+/i.test(argument) || credentialOption.test(argument) && (argument.includes("=") || index + 1 < arguments_.length)
  );
}
function errorCode(error) {
  if (error && typeof error === "object" && "code" in error && typeof error.code === "string" && /^[A-Z0-9_]+$/.test(error.code)) {
    return error.code;
  }
  return "SPAWN_FAILED";
}
function emptyResult(result) {
  return {
    ...result,
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false
  };
}
function redactOutput(value, cwd) {
  const root = cwd.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return value.replace(new RegExp(root, "gi"), "<project-root>").replace(/(https?:\/\/)[^/@\s]+@/gi, "$1[REDACTED]@").replace(/(\bBearer\s+)[^\s"']+/gi, "$1[REDACTED]").replace(
    /((?:_authToken|_auth|authorization|token|password|secret|api[-_]?key)["']?\s*[:=]\s*["']?)[^\s"',;}]+["']?/gi,
    "$1[REDACTED]"
  ).replace(/\b[A-Za-z]:\\[^\s"'<>|]+/g, "<path>").replace(/(?:^|\s)(\/(?:[^/\s]+\/)+[^\s"']*)/g, " <path>");
}
var BoundedOutput = class {
  constructor(limit) {
    this.limit = limit;
  }
  limit;
  value = Buffer.alloc(0);
  truncated = false;
  append(chunk) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const available = Math.max(0, this.limit - this.value.length);
    if (bytes.length > available) this.truncated = true;
    if (available > 0)
      this.value = Buffer.concat([this.value, bytes.subarray(0, available)]);
  }
  text() {
    return this.value.toString("utf8");
  }
};

// infrastructure/fnm-runtime.ts
var EXACT_NODE_VERSION = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
var npmCliPaths = /* @__PURE__ */ new Map();
function runWithProjectRuntime(request, spawnProcess = spawn2) {
  if (!request || typeof request !== "object" || typeof request.nodeVersion !== "string" || !EXACT_NODE_VERSION.test(request.nodeVersion)) {
    return Promise.resolve({
      kind: "invalid-request",
      reason: "node-version-must-be-exact",
      stdout: "",
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false
    });
  }
  if (typeof request.executable !== "string" || !Array.isArray(request.arguments)) {
    return Promise.resolve({
      kind: "invalid-request",
      reason: "command-invalid",
      stdout: "",
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false
    });
  }
  return runProcess(
    {
      executable: request.fnmExecutable,
      arguments: [
        "exec",
        "--using",
        request.nodeVersion,
        "--",
        request.executable,
        ...request.arguments
      ],
      cwd: request.cwd,
      env: request.env,
      timeoutMs: request.timeoutMs,
      terminationGraceMs: request.terminationGraceMs,
      maxOutputBytes: request.maxOutputBytes
    },
    spawnProcess
  );
}
async function runWithProjectNpm(request, runCommand = (command) => runWithProjectRuntime(command)) {
  if (!request || typeof request !== "object" || !EXACT_NODE_VERSION.test(String(request.nodeVersion)) || !Array.isArray(request.arguments) || request.arguments.some((argument) => typeof argument !== "string")) {
    return invalidRuntimeResult("npm-request-invalid");
  }
  const key = `${request.fnmExecutable}\0${request.nodeVersion}`;
  let npmCliPath = npmCliPaths.get(key);
  if (!npmCliPath) {
    const query = await runCommand({
      ...request,
      executable: "node",
      arguments: [
        "-p",
        "Buffer.from(require('node:path').join(require('node:path').dirname(process.execPath),'node_modules','npm','bin','npm-cli.js')).toString('base64')"
      ],
      timeoutMs: Math.min(request.timeoutMs, 3e4),
      maxOutputBytes: 8192
    });
    if (!isSuccessful(query)) return query;
    const resolvedPath = decodeNpmCliPath(query.stdout);
    if (!resolvedPath) return invalidRuntimeResult("npm-cli-path-invalid");
    npmCliPath = resolvedPath;
    npmCliPaths.set(key, resolvedPath);
  }
  return runCommand({
    ...request,
    executable: "node",
    arguments: [npmCliPath, ...request.arguments]
  });
}
function decodeNpmCliPath(value) {
  const encoded = value.trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length > 8192) {
    return null;
  }
  const decoded = Buffer.from(encoded, "base64").toString("utf8");
  const normalized = decoded.replace(/\\/g, "/").toLowerCase();
  if (decoded.includes("\0") || !(path.isAbsolute(decoded) || path.win32.isAbsolute(decoded)) || !normalized.endsWith("/node_modules/npm/bin/npm-cli.js")) {
    return null;
  }
  return decoded;
}
function isSuccessful(result) {
  return result.kind === "exited" && result.exitCode === 0 && !result.stdoutTruncated && !result.stderrTruncated;
}
function invalidRuntimeResult(reason) {
  return {
    kind: "invalid-request",
    reason,
    stdout: "",
    stderr: "",
    stdoutTruncated: false,
    stderrTruncated: false
  };
}

// infrastructure/infrastructure-error.ts
var InfrastructureError = class extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.name = "InfrastructureError";
  }
  code;
};

// infrastructure/project-files.ts
import { randomBytes } from "node:crypto";
import * as fs from "node:fs/promises";
import path2 from "node:path";
var ProjectFileSystem = class {
  constructor(fileSystem = fs) {
    this.fileSystem = fileSystem;
  }
  fileSystem;
  async canonicalProjectRoot(projectRoot) {
    try {
      if (typeof projectRoot !== "string" || projectRoot.trim().length === 0 || projectRoot.includes("\0")) {
        throw new Error();
      }
      const canonical = await this.fileSystem.realpath(
        path2.resolve(projectRoot)
      );
      if (!(await this.fileSystem.stat(canonical)).isDirectory())
        throw new Error();
      return canonical;
    } catch {
      throw new InfrastructureError(
        "project_root_invalid",
        "The project root is unavailable or is not a directory."
      );
    }
  }
  async resolveExistingPath(projectRoot, relativePath) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const candidate = this.resolveRelative(root, relativePath);
    try {
      const canonical = await this.fileSystem.realpath(candidate);
      if (!isWithin(root, canonical)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The requested path resolves outside the project root."
        );
      }
      return canonical;
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read."
      );
    }
  }
  async readJson(projectRoot, relativePath) {
    const content = await this.readText(projectRoot, relativePath);
    try {
      return JSON.parse(content);
    } catch {
      throw new InfrastructureError(
        "project_json_invalid",
        "The requested project file contains invalid JSON."
      );
    }
  }
  async readText(projectRoot, relativePath) {
    const canonicalPath = await this.resolveExistingPath(
      projectRoot,
      relativePath
    );
    try {
      return await this.fileSystem.readFile(canonicalPath, "utf8");
    } catch {
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read."
      );
    }
  }
  async readOptionalText(projectRoot, relativePath) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const candidate = this.resolveRelative(root, relativePath);
    let canonicalPath;
    try {
      canonicalPath = await this.fileSystem.realpath(candidate);
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return null;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read."
      );
    }
    if (!isWithin(root, canonicalPath)) {
      throw new InfrastructureError(
        "project_path_outside_root",
        "The requested path resolves outside the project root."
      );
    }
    try {
      return await this.fileSystem.readFile(canonicalPath, "utf8");
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return null;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The requested project file could not be read."
      );
    }
  }
  async ensureDirectory(projectRoot, relativeDirectory) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = relativeDirectory === "." ? root : this.resolveRelative(root, relativeDirectory);
    const relative = path2.relative(root, target);
    let current = root;
    for (const segment of relative.split(path2.sep).filter(Boolean)) {
      current = path2.join(current, segment);
      try {
        await this.fileSystem.mkdir(current);
      } catch (error) {
        if (!isErrorCode(error, "EEXIST")) {
          throw new InfrastructureError(
            "project_write_failed",
            "The project directory could not be created safely."
          );
        }
      }
      try {
        const stats = await this.fileSystem.lstat(current);
        const canonical = await this.fileSystem.realpath(current);
        if (stats.isSymbolicLink() || !stats.isDirectory() || !isWithin(root, canonical)) {
          throw new InfrastructureError(
            "project_path_outside_root",
            "The requested directory resolves outside the project root."
          );
        }
        current = canonical;
      } catch (error) {
        if (error instanceof InfrastructureError) throw error;
        throw new InfrastructureError(
          "project_write_failed",
          "The project directory could not be verified safely."
        );
      }
    }
    return current;
  }
  async writeAtomically(projectRoot, relativePath, content) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    const parent = await this.ensureDirectory(
      root,
      path2.relative(root, path2.dirname(target)) || "."
    );
    const destination = path2.join(parent, path2.basename(target));
    await this.assertExistingTargetIsRegularFile(destination, root);
    const temporary = path2.join(
      parent,
      `.${path2.basename(target)}.${randomBytes(12).toString("hex")}.tmp`
    );
    let handle;
    let temporaryCreated = false;
    let committed = false;
    try {
      handle = await this.fileSystem.open(temporary, "wx", 384);
      temporaryCreated = true;
      await handle.writeFile(content);
      await handle.sync();
      await handle.close();
      handle = void 0;
      await this.fileSystem.rename(temporary, destination);
      temporaryCreated = false;
      committed = true;
      const canonicalDestination = await this.fileSystem.realpath(destination);
      if (!isWithin(root, canonicalDestination)) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The write completed but its destination could not be verified safely."
        );
      }
      const written = await this.fileSystem.readFile(canonicalDestination);
      if (!Buffer.from(content).equals(written)) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The write completed but its contents did not pass verification."
        );
      }
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        committed ? "write_outcome_unconfirmed" : "project_write_failed",
        committed ? "The write may have completed but could not be verified." : "The project file could not be written atomically."
      );
    } finally {
      await handle?.close().catch(() => void 0);
      if (temporaryCreated)
        await this.fileSystem.rm(temporary, { force: true }).catch(() => void 0);
    }
  }
  async createExclusiveFile(projectRoot, relativePath, content) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    const parent = await this.ensureDirectory(
      root,
      path2.relative(root, path2.dirname(target)) || "."
    );
    const destination = path2.join(parent, path2.basename(target));
    let handle;
    let identity;
    try {
      handle = await this.fileSystem.open(destination, "wx", 384);
      const stats = await handle.stat();
      identity = { device: stats.dev, inode: stats.ino };
      await handle.writeFile(content, "utf8");
      await handle.sync();
      await handle.close();
      handle = void 0;
      const canonical = await this.fileSystem.realpath(destination);
      const written = await this.fileSystem.readFile(canonical, "utf8");
      if (!isWithin(root, canonical) || written !== content) {
        throw new InfrastructureError(
          "write_outcome_unconfirmed",
          "The exclusive file was created but could not be verified safely."
        );
      }
      return { created: true, identity };
    } catch (error) {
      if (isErrorCode(error, "EEXIST")) return { created: false };
      if (identity)
        await this.removeIfIdentityMatches(
          projectRoot,
          relativePath,
          identity
        ).catch(() => false);
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        "project_write_failed",
        "The exclusive project file could not be created safely."
      );
    } finally {
      await handle?.close().catch(() => void 0);
    }
  }
  async removeIfIdentityMatches(projectRoot, relativePath, identity) {
    const root = await this.canonicalProjectRoot(projectRoot);
    const target = this.resolveRelative(root, relativePath);
    try {
      const stats = await this.fileSystem.lstat(target);
      if (stats.isSymbolicLink() || stats.dev !== identity.device || stats.ino !== identity.inode)
        return false;
      const canonicalParent = await this.fileSystem.realpath(
        path2.dirname(target)
      );
      if (!isWithin(root, canonicalParent)) return false;
      await this.fileSystem.unlink(target);
      return true;
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) return false;
      throw new InfrastructureError(
        "project_write_failed",
        "The owned project file could not be removed safely."
      );
    }
  }
  resolveRelative(root, relativePath) {
    if (typeof relativePath !== "string" || relativePath.trim().length === 0 || relativePath.includes("\0") || path2.isAbsolute(relativePath) || path2.win32.isAbsolute(relativePath) || /^[a-zA-Z]:/.test(relativePath) || relativePath.split(/[\\/]+/).some((segment) => segment === "..")) {
      throw new InfrastructureError(
        "project_path_invalid",
        "Project paths must be relative and cannot traverse parent directories."
      );
    }
    const normalized = path2.resolve(
      root,
      relativePath.replace(/[\\/]+/g, path2.sep)
    );
    if (!isWithin(root, normalized)) {
      throw new InfrastructureError(
        "project_path_outside_root",
        "The requested path resolves outside the project root."
      );
    }
    return normalized;
  }
  async assertExistingTargetIsRegularFile(destination, root) {
    try {
      const stats = await this.fileSystem.lstat(destination);
      const parent = await this.fileSystem.realpath(path2.dirname(destination));
      if (stats.isSymbolicLink() || !isWithin(root, parent)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The requested file target is not a safe project file."
        );
      }
      if (!stats.isFile())
        throw new InfrastructureError(
          "project_write_failed",
          "The requested target is not a regular project file."
        );
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      if (isErrorCode(error, "ENOENT")) return;
      throw new InfrastructureError(
        "project_file_read_failed",
        "The existing project file could not be verified safely."
      );
    }
  }
};
function isWithin(root, candidate) {
  const relative = path2.relative(root, candidate);
  return relative === "" || relative !== ".." && !relative.startsWith(`..${path2.sep}`) && !path2.isAbsolute(relative);
}
function isErrorCode(error, code) {
  return Boolean(
    error && typeof error === "object" && "code" in error && error.code === code
  );
}

// infrastructure/baseline-dependencies.ts
var MAX_PROPOSAL_PACKAGES = 50;
var MAX_PEER_RANGES = 20;
var MAX_DEPENDENCY_NODES = 1e4;
var NpmBaselineDependencyProposalReader = class {
  constructor(options) {
    this.options = options;
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime = options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm = options.runNpm ?? ((request) => runWithProjectNpm(request, this.runRuntime));
  }
  options;
  files;
  runRuntime;
  runNpm;
  async read(projectRoot, run) {
    const nodeVersion = run.discoveryPlan.runtimePlan.selected?.nodeVersion;
    if (!isExactVersion(nodeVersion)) {
      throw new InfrastructureError(
        "run_record_invalid",
        "The run does not contain an exact selected Node runtime."
      );
    }
    const canonicalRoot = await this.files.canonicalProjectRoot(projectRoot);
    const result = await this.runNpm(
      this.npmRequest(canonicalRoot, nodeVersion, ["ls", "--all", "--json"])
    );
    if (result.kind !== "exited" || ![0, 1].includes(result.exitCode) || result.stdoutTruncated || result.stderrTruncated) {
      throw new InfrastructureError(
        "registry_metadata_unavailable",
        "npm could not return a complete structured dependency tree."
      );
    }
    let tree;
    try {
      tree = JSON.parse(result.stdout);
    } catch {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "npm returned invalid JSON for the dependency tree."
      );
    }
    if (!isRecord7(tree)) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "npm returned an invalid dependency tree."
      );
    }
    const missing = collectMissingPeers(tree);
    if (missing.length > MAX_PROPOSAL_PACKAGES) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "The structured missing-peer proposal exceeds its package limit."
      );
    }
    const proposal = [];
    for (const entry of missing) {
      const candidates = /* @__PURE__ */ new Set();
      for (const range of entry.requiredRanges) {
        const versionResult = await this.runNpm(
          this.npmRequest(canonicalRoot, nodeVersion, [
            "view",
            `${entry.name}@${range}`,
            "version",
            "--json"
          ])
        );
        if (!isCompleteExit(versionResult, 0)) {
          throw new InfrastructureError(
            "registry_metadata_unavailable",
            "The configured npm registry could not resolve a peer range."
          );
        }
        const versions = parseVersionList(versionResult.stdout);
        if (versions === null) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "The configured npm registry returned invalid version data."
          );
        }
        for (const version of versions) candidates.add(version);
      }
      const installVersion = selectHighestSatisfyingSemverVersion(
        [...candidates],
        entry.requiredRanges
      );
      if (!installVersion) {
        throw new InfrastructureError(
          "registry_metadata_unavailable",
          "No exact registry version satisfies every missing peer range."
        );
      }
      proposal.push({
        name: entry.name,
        installVersion,
        requiredRanges: entry.requiredRanges,
        requiredBy: entry.requiredBy
      });
    }
    return proposal;
  }
  npmRequest(projectRoot, nodeVersion, arguments_) {
    return {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion,
      arguments: arguments_,
      cwd: projectRoot,
      env: this.options.environment,
      timeoutMs: 12e4,
      terminationGraceMs: 5e3,
      maxOutputBytes: 1048576
    };
  }
};
var NpmBaselineDependencyInstaller = class {
  constructor(options) {
    this.options = options;
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime = options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm = options.runNpm ?? ((request) => runWithProjectNpm(request, this.runRuntime));
  }
  options;
  files;
  runRuntime;
  runNpm;
  async install(input) {
    if (!isValidInstallRequest(input)) {
      return { outcome: "failed", packageStateHash: null };
    }
    let canonicalRoot;
    let originalPackage;
    let originalLock;
    try {
      canonicalRoot = await this.files.canonicalProjectRoot(input.projectRoot);
      const before = await this.gitStatus(canonicalRoot, input.nodeVersion);
      if (before === null || before.length !== 0) {
        return { outcome: "failed", packageStateHash: null };
      }
      originalPackage = await this.files.readText(
        canonicalRoot,
        "package.json"
      );
      originalLock = await this.files.readText(
        canonicalRoot,
        "package-lock.json"
      );
      const install = await this.runNpm({
        ...this.npmRequest(canonicalRoot, input.nodeVersion),
        arguments: [
          "install",
          "--save-prod",
          "--save-exact",
          "--ignore-scripts",
          "--no-audit",
          "--no-fund",
          ...input.packages.map(
            ({ name, installVersion }) => `${name}@${installVersion}`
          )
        ]
      });
      const installPaths = await this.gitStatus(
        canonicalRoot,
        input.nodeVersion
      );
      if (!isCompleteExit(install, 0) || !isAllowedPackageChanges(installPaths) || !await this.hasExactDeclarations(canonicalRoot, input.packages)) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock
        );
        return { outcome: "failed", packageStateHash: null };
      }
      const tree = await this.runNpm({
        ...this.npmRequest(canonicalRoot, input.nodeVersion),
        arguments: ["ls", "--all"]
      });
      const finalPaths = await this.gitStatus(canonicalRoot, input.nodeVersion);
      if (!isCompleteExit(tree, 0) || !isAllowedPackageChanges(finalPaths)) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock
        );
        return { outcome: "failed", packageStateHash: null };
      }
      const packageText = await this.files.readText(
        canonicalRoot,
        "package.json"
      );
      const lockText = await this.files.readText(
        canonicalRoot,
        "package-lock.json"
      );
      return {
        outcome: "installed",
        packageStateHash: `sha256:${createHash("sha256").update(packageText).update("\0").update(lockText).digest("hex")}`
      };
    } catch {
      if (canonicalRoot && originalPackage !== void 0 && originalLock !== void 0) {
        await this.rollback(
          canonicalRoot,
          input.nodeVersion,
          originalPackage,
          originalLock
        );
      }
      return { outcome: "failed", packageStateHash: null };
    }
  }
  npmRequest(projectRoot, nodeVersion) {
    return {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion,
      arguments: [],
      cwd: projectRoot,
      env: this.options.environment,
      timeoutMs: 6e5,
      terminationGraceMs: 1e4,
      maxOutputBytes: 262144
    };
  }
  async gitStatus(projectRoot, nodeVersion) {
    try {
      const result = await this.runRuntime({
        fnmExecutable: this.options.fnmExecutable,
        nodeVersion,
        executable: "git",
        arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd: projectRoot,
        env: this.options.environment,
        timeoutMs: 3e4,
        terminationGraceMs: 5e3,
        maxOutputBytes: 1048576
      });
      if (!isCompleteExit(result, 0)) return null;
      return parseGitStatus(result.stdout);
    } catch {
      return null;
    }
  }
  async hasExactDeclarations(projectRoot, packages) {
    try {
      const manifest = asRecord(
        await this.files.readJson(projectRoot, "package.json")
      );
      const lock = asRecord(
        await this.files.readJson(projectRoot, "package-lock.json")
      );
      const lockedPackages = asRecord(asRecord(lock.packages)[""]);
      const lockedDependencies = asRecord(lock.dependencies);
      return packages.every((item) => {
        const declared = [
          "dependencies",
          "devDependencies",
          "optionalDependencies",
          "peerDependencies"
        ].filter((key) => Object.hasOwn(asRecord(manifest[key]), item.name));
        const lockSections = [
          lockedPackages.dependencies,
          lockedPackages.devDependencies,
          lockedPackages.optionalDependencies,
          lockedPackages.peerDependencies
        ];
        const rootLockMatches = lockSections.filter(
          (section) => asRecord(section)[item.name] === item.installVersion
        );
        const lockEntry = asRecord(
          asRecord(lock.packages)[`node_modules/${item.name}`]
        );
        const legacyEntry = asRecord(lockedDependencies[item.name]);
        return declared.length === 1 && asRecord(manifest[declared[0]])[item.name] === item.installVersion && rootLockMatches.length === 1 && (lockEntry.version === item.installVersion || legacyEntry.version === item.installVersion);
      });
    } catch {
      return false;
    }
  }
  async rollback(projectRoot, nodeVersion, originalPackage, originalLock) {
    try {
      if (await this.gitStatus(projectRoot, nodeVersion) === null)
        return false;
      for (const [file, original] of [
        ["package.json", originalPackage],
        ["package-lock.json", originalLock]
      ]) {
        const current = await this.files.readOptionalText(projectRoot, file);
        if (current !== original) {
          await this.files.writeAtomically(projectRoot, file, original);
        }
      }
      const [restoredPackage, restoredLock, after] = await Promise.all([
        this.files.readText(projectRoot, "package.json"),
        this.files.readText(projectRoot, "package-lock.json"),
        this.gitStatus(projectRoot, nodeVersion)
      ]);
      return restoredPackage === originalPackage && restoredLock === originalLock && after !== null && after.length === 0;
    } catch {
      return false;
    }
  }
};
function collectMissingPeers(tree) {
  const dependencies = tree.dependencies;
  if (!isRecord7(dependencies)) return [];
  const missing = /* @__PURE__ */ new Map();
  let visited = 0;
  const walk = (children, parents, depth) => {
    if (depth > 100) {
      throw new InfrastructureError(
        "registry_metadata_invalid",
        "The structured dependency tree exceeds its depth limit."
      );
    }
    for (const [name, raw] of Object.entries(children)) {
      visited += 1;
      if (visited > MAX_DEPENDENCY_NODES) {
        throw new InfrastructureError(
          "registry_metadata_invalid",
          "The structured dependency tree exceeds its node limit."
        );
      }
      if (!isRecord7(raw)) continue;
      if (raw.missing === true && raw.peer === true && raw.peerOptional !== true) {
        const range = raw.required;
        if (typeof range !== "string" || range.length > 256) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "A missing peer lacks a bounded structured version range."
          );
        }
        const parent = parents.at(-1) ?? "project root";
        const entry = missing.get(name) ?? {
          ranges: /* @__PURE__ */ new Set(),
          parents: /* @__PURE__ */ new Set()
        };
        entry.ranges.add(range);
        entry.parents.add(parent);
        if (entry.ranges.size > MAX_PEER_RANGES) {
          throw new InfrastructureError(
            "registry_metadata_invalid",
            "A missing peer has too many distinct required ranges."
          );
        }
        missing.set(name, entry);
      }
      if (isRecord7(raw.dependencies)) {
        const version = typeof raw.version === "string" ? raw.version : "unknown";
        walk(raw.dependencies, [...parents, `${name}@${version}`], depth + 1);
      }
    }
  };
  walk(dependencies, [], 0);
  return [...missing.entries()].map(([name, value]) => ({
    name,
    requiredRanges: [...value.ranges].sort(),
    requiredBy: [...value.parents].sort()
  })).sort((left, right) => left.name.localeCompare(right.name));
}
function parseVersionList(text) {
  try {
    const parsed = JSON.parse(text);
    const versions = typeof parsed === "string" ? [parsed] : parsed;
    if (!Array.isArray(versions) || versions.length === 0 || versions.some((version) => !isExactVersion(version))) {
      return null;
    }
    return versions;
  } catch {
    return null;
  }
}
function parseGitStatus(text) {
  if (text.length === 0) return [];
  if (!text.endsWith("\0")) return null;
  const entries = [];
  for (const item of text.split("\0").filter(Boolean)) {
    if (item.length < 4 || item[2] !== " ") return null;
    const status = item.slice(0, 2);
    if (status !== " M") return null;
    entries.push({ status, path: item.slice(3) });
  }
  return entries;
}
function isAllowedPackageChanges(entries) {
  return Boolean(
    entries && entries.every(
      ({ path: file }) => file === "package.json" || file === "package-lock.json"
    )
  );
}
function isValidInstallRequest(value) {
  const names = /* @__PURE__ */ new Set();
  return Boolean(
    isRecord7(value) && typeof value.projectRoot === "string" && value.projectRoot.trim().length > 0 && typeof value.runId === "string" && isExactVersion(value.nodeVersion) && Array.isArray(value.packages) && value.packages.length > 0 && value.packages.length <= MAX_PROPOSAL_PACKAGES && value.packages.every((item) => {
      if (!isRecord7(item) || typeof item.name !== "string" || !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) || item.name.startsWith("@angular/") || names.has(item.name) || !isExactVersion(item.installVersion) || parseExactSemverVersion(item.installVersion)?.version !== item.installVersion || !Array.isArray(item.requiredRanges) || item.requiredRanges.length === 0 || item.requiredRanges.length > MAX_PEER_RANGES || !item.requiredRanges.every(isValidSemverRange) || !satisfiesAllSemverRanges(item.installVersion, item.requiredRanges) || !Array.isArray(item.requiredBy) || item.requiredBy.length === 0 || item.requiredBy.length > 100 || !item.requiredBy.every(
        (parent) => typeof parent === "string" && parent.length <= 256 && !/[\0\r\n]/.test(parent)
      )) {
        return false;
      }
      names.add(item.name);
      return true;
    })
  );
}
function isCompleteExit(result, code) {
  return result.kind === "exited" && result.exitCode === code && !result.stdoutTruncated && !result.stderrTruncated;
}
function isExactVersion(value) {
  return typeof value === "string" && /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(value);
}
function asRecord(value) {
  return isRecord7(value) ? value : {};
}
function isRecord7(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

// infrastructure/discovery-persistence.ts
import { createHash as createHash2 } from "node:crypto";
var DISCOVERY_PATH = ".angular-migration/discovery.json";
var DiscoveryRecordStoreAdapter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async read(projectRoot) {
    const text = await this.files.readOptionalText(projectRoot, DISCOVERY_PATH);
    if (text === null) return null;
    try {
      return JSON.parse(text);
    } catch {
      throw new InfrastructureError(
        "discovery_record_invalid",
        "The persisted discovery record contains invalid JSON."
      );
    }
  }
  async write(projectRoot, record) {
    await this.files.writeAtomically(
      projectRoot,
      DISCOVERY_PATH,
      `${JSON.stringify(record)}
`
    );
  }
};
var ProjectValueHasher = class {
  async hash(value) {
    let serialized;
    try {
      serialized = JSON.stringify(canonicalize(value));
    } catch {
      throw new InfrastructureError(
        "hash_input_invalid",
        "The discovery value cannot be hashed safely."
      );
    }
    if (serialized === void 0) {
      throw new InfrastructureError(
        "hash_input_invalid",
        "The discovery value cannot be hashed safely."
      );
    }
    return `sha256:${createHash2("sha256").update(serialized).digest("hex")}`;
  }
  async hashText(value) {
    if (typeof value !== "string") {
      throw new InfrastructureError(
        "hash_input_invalid",
        "Text content cannot be hashed safely."
      );
    }
    return `sha256:${createHash2("sha256").update(value, "utf8").digest("hex")}`;
  }
};
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    const record = value;
    return Object.fromEntries(
      Object.keys(record).sort().map((key) => [key, canonicalize(record[key])])
    );
  }
  return value;
}

// infrastructure/documentation-store.ts
import { createHash as createHash3 } from "node:crypto";
import * as fs2 from "node:fs/promises";
import path3 from "node:path";
var MAX_DOCUMENT_BYTES2 = 262144;
var DocumentationArtifactStoreAdapter = class {
  constructor(files = new ProjectFileSystem(), options = {}) {
    this.files = files;
    this.environment = options.environment ?? Object.fromEntries(
      Object.entries(process.env).filter(
        (entry) => typeof entry[1] === "string"
      )
    );
    this.fnmExecutable = options.fnmExecutable ?? "fnm";
    this.runRuntime = options.runRuntime ?? ((request) => runWithProjectRuntime(request));
  }
  files;
  environment;
  fnmExecutable;
  runRuntime;
  readResearchSubmission(projectRoot, runId) {
    return this.readInbox(projectRoot, runId, "research");
  }
  readPublishSubmission(projectRoot, runId) {
    return this.readInbox(projectRoot, runId, "publish");
  }
  readResearch(projectRoot, runId) {
    return this.readRecord(projectRoot, runId, "research");
  }
  readPublication(projectRoot, runId) {
    return this.readRecord(projectRoot, runId, "publication");
  }
  async writeResearch(projectRoot, runId, record) {
    await this.writeRecord(projectRoot, runId, "research", record);
  }
  async writePublication(projectRoot, runId, record) {
    await this.writeRecord(projectRoot, runId, "publication", record);
  }
  async inspectOutput(projectRoot, outputDirectory) {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const directory = await this.resolveOutputDirectory(root, outputDirectory);
    if (directory === null) return null;
    const entries = await fs2.readdir(directory, { withFileTypes: true });
    const result = [];
    for (const entry of entries) {
      if (!entry.isFile() || entry.isSymbolicLink()) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output directory contains a non-file entry."
        );
      }
      const content = await fs2.readFile(path3.join(directory, entry.name));
      if (content.byteLength > MAX_DOCUMENT_BYTES2) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "A documentation file exceeds the supported size limit."
        );
      }
      result.push({
        path: `${outputDirectory}/${entry.name}`,
        sha256: sha256(content)
      });
    }
    return result.sort((left, right) => left.path.localeCompare(right.path));
  }
  async inspectGitSnapshot(projectRoot, nodeVersion) {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const head = await this.runGit(root, nodeVersion, [
      "rev-parse",
      "--verify",
      "HEAD"
    ]);
    if (!isCompleteExit2(head, 0) || !/^[a-f0-9]{40,64}$/i.test(head.stdout.trim())) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The documentation operation cannot verify the current Git HEAD."
      );
    }
    const status = await this.runGit(root, nodeVersion, [
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      "--",
      ".",
      ":!.angular-migration"
    ]);
    if (!isCompleteExit2(status, 0)) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The documentation operation cannot verify changed project paths."
      );
    }
    const changes = parseGitStatus2(status.stdout);
    if (changes === null) {
      throw new InfrastructureError(
        "git_inspection_failed",
        "The Git status contains an unsupported path change."
      );
    }
    return { head: head.stdout.trim().toLowerCase(), changes };
  }
  async publishFiles(input) {
    if (!isPublishFilesRequest(input)) {
      throw new InfrastructureError(
        "documentation_submission_invalid",
        "The documentation file set is invalid."
      );
    }
    const current = await this.inspectOutput(
      input.projectRoot,
      input.outputDirectory
    );
    if (!sameFileSet2(current, input.expectedExistingFiles)) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The documentation output changed after approval."
      );
    }
    const gitBefore = await this.inspectGitSnapshot(
      input.projectRoot,
      input.nodeVersion
    );
    if (!sameGitSnapshot2(gitBefore, input.expectedGitSnapshot)) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The project Git state changed after documentation approval."
      );
    }
    if (current !== null) {
      throw new InfrastructureError(
        "documentation_publish_conflict",
        "The documentation output already exists and will not be overwritten."
      );
    }
    const root = await this.files.canonicalProjectRoot(input.projectRoot);
    const parent = await this.files.ensureDirectory(root, "docs/migration");
    const target = path3.join(root, ...input.outputDirectory.split("/"));
    const staging = await fs2.mkdtemp(path3.join(parent, ".migration-docs-"));
    let renamed = false;
    try {
      for (const file of input.files) {
        const name = file.path.slice(`${input.outputDirectory}/`.length);
        const destination = path3.join(staging, name);
        const handle = await fs2.open(destination, "wx", 384);
        try {
          await handle.writeFile(file.content, "utf8");
          await handle.sync();
        } finally {
          await handle.close();
        }
        const actualHash = sha256(Buffer.from(file.content, "utf8"));
        if (actualHash !== file.sha256) {
          throw new InfrastructureError(
            "documentation_submission_invalid",
            "A documentation file failed its content hash check."
          );
        }
      }
      if (await this.inspectOutput(input.projectRoot, input.outputDirectory) !== null) {
        throw new InfrastructureError(
          "documentation_publish_conflict",
          "The documentation output appeared during publication."
        );
      }
      await fs2.rename(staging, target);
      renamed = true;
      const published = await this.inspectOutput(
        input.projectRoot,
        input.outputDirectory
      );
      if (!sameFileSet2(
        published,
        input.files.map(({ path: filePath, sha256: hash }) => ({
          path: filePath,
          sha256: hash
        })).sort((left, right) => left.path.localeCompare(right.path))
      )) {
        throw new InfrastructureError(
          "documentation_rollback_unconfirmed",
          "The published documentation could not be verified after the atomic write."
        );
      }
      const gitAfter = await this.inspectGitSnapshot(
        input.projectRoot,
        input.nodeVersion
      );
      if (!onlyExpectedDocumentationChanges2(gitBefore, gitAfter, input.files)) {
        throw new InfrastructureError(
          "documentation_publish_conflict",
          "Publication changed paths outside the approved documentation set."
        );
      }
      return sha256(Buffer.from(JSON.stringify(published), "utf8"));
    } catch (error) {
      if (renamed) {
        try {
          const published = await this.inspectOutput(
            input.projectRoot,
            input.outputDirectory
          );
          const expected = input.files.map(({ path: filePath, sha256: hash }) => ({
            path: filePath,
            sha256: hash
          })).sort((left, right) => left.path.localeCompare(right.path));
          if (!sameFileSet2(published, expected)) throw new Error();
          await fs2.rename(target, staging);
          await fs2.rm(staging, { recursive: true, force: true });
          renamed = false;
          const restored = await this.inspectGitSnapshot(
            input.projectRoot,
            input.nodeVersion
          );
          if (!sameGitSnapshot2(restored, gitBefore)) throw new Error();
        } catch {
          throw new InfrastructureError(
            "documentation_rollback_unconfirmed",
            "Documentation changed but its rollback could not be verified."
          );
        }
      } else {
        await fs2.rm(staging, { recursive: true, force: true }).catch(() => void 0);
      }
      if (error instanceof InfrastructureError) throw error;
      throw new InfrastructureError(
        renamed ? "documentation_rollback_unconfirmed" : "documentation_output_invalid",
        renamed ? "Documentation was written but its final state could not be confirmed." : "The documentation could not be published safely."
      );
    }
  }
  async readInbox(projectRoot, runId, mode) {
    const relative = `.angular-migration/documentation-inbox/${runId}.${mode}.json`;
    const text = await this.files.readOptionalText(projectRoot, relative);
    if (text === null) {
      throw new InfrastructureError(
        "documentation_submission_missing",
        "No controller-readable documentation submission is available."
      );
    }
    return parseJson(text, "documentation_submission_invalid");
  }
  async readRecord(projectRoot, runId, kind) {
    const text = await this.files.readOptionalText(
      projectRoot,
      `.angular-migration/documentation/${runId}/${kind}.json`
    );
    return text === null ? null : parseJson(text, "documentation_record_invalid");
  }
  async writeRecord(projectRoot, runId, kind, record) {
    await this.files.writeAtomically(
      projectRoot,
      `.angular-migration/documentation/${runId}/${kind}.json`,
      `${JSON.stringify(record)}
`
    );
  }
  async resolveOutputDirectory(root, relative) {
    if (!/^docs\/migration\/v[1-9]\d*$/.test(relative)) {
      throw new InfrastructureError(
        "project_path_invalid",
        "The documentation output path is not allowed."
      );
    }
    let current = root;
    for (const segment of relative.split("/")) {
      current = path3.join(current, segment);
      let stats;
      try {
        stats = await fs2.lstat(current);
      } catch (error) {
        if (isErrorCode2(error, "ENOENT")) return null;
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output path could not be inspected safely."
        );
      }
      if (stats.isSymbolicLink() || !stats.isDirectory()) {
        throw new InfrastructureError(
          "documentation_output_invalid",
          "The documentation output path is not a regular directory."
        );
      }
      const real = await fs2.realpath(current);
      if (!isWithin2(root, real)) {
        throw new InfrastructureError(
          "project_path_outside_root",
          "The documentation output resolves outside the project."
        );
      }
      current = real;
    }
    return current;
  }
  runGit(cwd, nodeVersion, arguments_) {
    return this.runRuntime({
      fnmExecutable: this.fnmExecutable,
      nodeVersion,
      executable: "git",
      arguments: arguments_,
      cwd,
      env: this.environment,
      timeoutMs: 3e4,
      terminationGraceMs: 5e3,
      maxOutputBytes: 262144
    });
  }
};
function parseJson(text, code) {
  try {
    return JSON.parse(text);
  } catch {
    throw new InfrastructureError(
      code,
      "The documentation artifact contains invalid JSON."
    );
  }
}
function isPublishFilesRequest(value) {
  return Boolean(
    value && typeof value === "object" && typeof value.projectRoot === "string" && typeof value.outputDirectory === "string" && isExactVersion2(value.nodeVersion) && isDocumentationGitSnapshot2(
      value.expectedGitSnapshot
    ) && /^docs\/migration\/v[1-9]\d*$/.test(
      String(value.outputDirectory)
    ) && Array.isArray(value.files) && value.files.length === REQUIRED_MIGRATION_DOCUMENTS.length && value.files.every(
      (file, index) => {
        if (!file || typeof file !== "object") return false;
        const item = file;
        const expectedPath = `${String(value.outputDirectory)}/${REQUIRED_MIGRATION_DOCUMENTS[index]}`;
        return item.path === expectedPath && typeof item.content === "string" && Buffer.byteLength(item.content, "utf8") <= MAX_DOCUMENT_BYTES2 && typeof item.sha256 === "string" && /^sha256:[a-f0-9]{64}$/.test(item.sha256) && sha256(Buffer.from(item.content, "utf8")) === item.sha256;
      }
    )
  );
}
function sameFileSet2(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}
function sha256(value) {
  return `sha256:${createHash3("sha256").update(value).digest("hex")}`;
}
function isWithin2(root, candidate) {
  const relative = path3.relative(root, candidate);
  return relative === "" || relative !== ".." && !relative.startsWith(`..${path3.sep}`) && !path3.isAbsolute(relative);
}
function isErrorCode2(error, code) {
  return Boolean(
    error && typeof error === "object" && "code" in error && error.code === code
  );
}
function parseGitStatus2(text) {
  if (text.length === 0) return [];
  if (!text.endsWith("\0")) return null;
  const result = [];
  for (const entry of text.split("\0").filter(Boolean)) {
    if (entry.length < 4 || entry[2] !== " ") return null;
    const status = entry.slice(0, 2);
    const file = entry.slice(3);
    if (/^[RC]/.test(status) || result.some(({ path: prior }) => prior === file))
      return null;
    result.push({ path: file, status });
  }
  return result.sort((left, right) => left.path.localeCompare(right.path));
}
function sameGitSnapshot2(left, right) {
  return left.head === right.head && JSON.stringify(left.changes) === JSON.stringify(right.changes);
}
function onlyExpectedDocumentationChanges2(before, after, files) {
  if (before.head !== after.head) return false;
  const prior = new Map(
    before.changes.map((entry) => [entry.path, entry.status])
  );
  const next = new Map(
    after.changes.map((entry) => [entry.path, entry.status])
  );
  if ([...prior].some(([file, status]) => next.get(file) !== status))
    return false;
  const added = [...next.keys()].filter((file) => !prior.has(file)).sort();
  const expected = files.map(({ path: file }) => file).sort();
  return JSON.stringify(added) === JSON.stringify(expected) && added.every((file) => next.get(file) === "??");
}
function isDocumentationGitSnapshot2(value) {
  return Boolean(
    value && typeof value === "object" && typeof value.head === "string" && /^[a-f0-9]{40,64}$/i.test(
      String(value.head)
    ) && Array.isArray(value.changes) && value.changes.every(
      (entry) => Boolean(
        entry && typeof entry === "object" && typeof entry.path === "string" && typeof entry.status === "string"
      )
    )
  );
}
function isCompleteExit2(result, code) {
  return result.kind === "exited" && result.exitCode === code && !result.stdoutTruncated && !result.stderrTruncated;
}
function isExactVersion2(value) {
  return typeof value === "string" && /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(value);
}

// infrastructure/hook-runtime.ts
import * as fs3 from "node:fs/promises";
import path4 from "node:path";
var RUNTIME_ASSETS = [
  [
    "scripts/hooks/copilot-policy-ts.ps1",
    ".angular-migration/runtime/copilot-policy-ts.ps1"
  ],
  [
    "src/runtime/copilot-policy.mjs",
    ".angular-migration/runtime/copilot-policy.mjs"
  ]
];
var MAX_ASSET_BYTES = 262144;
var HookRuntimeDeployer = class {
  constructor(pluginRoot, files = new ProjectFileSystem()) {
    this.pluginRoot = pluginRoot;
    this.files = files;
  }
  pluginRoot;
  files;
  async deploy(projectRoot) {
    for (const [sourceRelative, projectRelative] of RUNTIME_ASSETS) {
      const source = path4.resolve(
        this.pluginRoot,
        ...sourceRelative.split("/")
      );
      let content;
      try {
        const stats = await fs3.lstat(source);
        if (!stats.isFile() || stats.isSymbolicLink() || stats.size > MAX_ASSET_BYTES)
          throw new Error();
        content = await fs3.readFile(source);
      } catch {
        throw new InfrastructureError(
          "hook_runtime_unavailable",
          "A required controller hook runtime asset is unavailable."
        );
      }
      await this.files.writeAtomically(projectRoot, projectRelative, content);
    }
  }
};

// infrastructure/project-discovery-reader.ts
var import_semver3 = __toESM(require_semver2(), 1);
import { createHash as createHash5 } from "node:crypto";
import * as fs4 from "node:fs/promises";
import path5 from "node:path";

// infrastructure/project-facts-reader.ts
import { createHash as createHash4 } from "node:crypto";
var DEPENDENCY_SECTIONS = [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies"
];
var ProjectFactsReaderAdapter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async readProjectFacts(projectRoot) {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const packageJson = asRecord2(
      await this.files.readJson(root, "package.json")
    );
    const lockfile = asRecord2(
      await this.files.readJson(root, "package-lock.json")
    );
    const declaredRange = readDeclaredAngularSpecification(packageJson);
    const resolvedVersion = parseExactSemverVersion(
      readLockedAngularVersion(lockfile)
    );
    if (!isValidSemverRange(declaredRange) || resolvedVersion === null || !satisfiesAllSemverRanges(resolvedVersion.version, [declaredRange])) {
      throw invalidFacts(
        "The declared Angular core range does not include its locked version."
      );
    }
    const projectId = createHash4("sha256").update(root).digest("hex");
    return {
      projectId: createProjectId(`sha256:${projectId}`),
      angularMajor: createAngularMajor(resolvedVersion.major)
    };
  }
};
function readDeclaredAngularSpecification(packageJson) {
  const specifications = [];
  for (const section of DEPENDENCY_SECTIONS) {
    if (!(section in packageJson)) continue;
    const dependencies = asRecord2(packageJson[section]);
    if (!Object.hasOwn(dependencies, "@angular/core")) continue;
    const specification = dependencies["@angular/core"];
    if (typeof specification !== "string")
      throw invalidFacts(
        "Angular core must use a string npm version specification."
      );
    specifications.push(specification);
  }
  if (specifications.length !== 1)
    throw invalidFacts(
      "Exactly one direct Angular core dependency is required."
    );
  return specifications[0];
}
function readLockedAngularVersion(lockfile) {
  const lockfileVersion = lockfile.lockfileVersion;
  if (lockfileVersion !== 1 && lockfileVersion !== 2 && lockfileVersion !== 3) {
    throw invalidFacts("The npm lockfile version is not supported.");
  }
  const section = lockfileVersion === 1 ? "dependencies" : "packages";
  const entries = asRecord2(lockfile[section]);
  const angularEntry = lockfileVersion === 1 ? asRecord2(entries["@angular/core"]) : asRecord2(entries["node_modules/@angular/core"]);
  if (typeof angularEntry.version !== "string")
    throw invalidFacts(
      "The npm lockfile has no resolved Angular core version."
    );
  const version = parseExactSemverVersion(angularEntry.version);
  if (version === null)
    throw invalidFacts("The resolved Angular core version is not exact.");
  return version.version;
}
function asRecord2(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw invalidFacts("Project metadata has an invalid object shape.");
  }
  return value;
}
function invalidFacts(message) {
  return new InfrastructureError("project_facts_invalid", message);
}

// infrastructure/project-discovery-reader.ts
var SECTIONS = [
  "dependencies",
  "devDependencies",
  "optionalDependencies",
  "peerDependencies"
];
var FRAMEWORK_PACKAGES = /* @__PURE__ */ new Set([
  "animations",
  "common",
  "compiler",
  "compiler-cli",
  "core",
  "elements",
  "forms",
  "language-service",
  "localize",
  "platform-browser",
  "platform-browser-dynamic",
  "platform-server",
  "platform-webworker",
  "platform-webworker-dynamic",
  "router",
  "service-worker",
  "upgrade"
]);
var FINGERPRINT_FILES = [
  "package.json",
  "package-lock.json",
  "angular.json",
  ".npmrc",
  ".nvmrc",
  ".node-version",
  ".tool-versions",
  "nx.json",
  "yarn.lock",
  "pnpm-lock.yaml"
];
var ProjectDiscoveryReaderAdapter = class {
  constructor(options) {
    this.options = options;
    this.files = options.files ?? new ProjectFileSystem();
    this.runCommand = options.runProcess ?? ((request) => runProcess(request));
    this.runRuntimeCommand = options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpmCommand = options.runNpm ?? ((request) => runWithProjectNpm(request, this.runRuntimeCommand));
  }
  options;
  files;
  runCommand;
  runRuntimeCommand;
  runNpmCommand;
  async read(projectRoot, targetMajor) {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const packageJson = asRecord3(
      await this.files.readJson(root, "package.json")
    );
    const lockfile = asRecord3(
      await this.files.readJson(root, "package-lock.json")
    );
    const angular = asRecord3(await this.files.readJson(root, "angular.json"));
    const facts = await new ProjectFactsReaderAdapter(
      this.files
    ).readProjectFacts(root);
    createAngularTransition(facts.angularMajor, targetMajor);
    const lockfileVersion = Number(lockfile.lockfileVersion);
    const declarations = readDependencies(packageJson, lockfile);
    const issues = [];
    const scripts = asRecordOrEmpty(packageJson.scripts);
    const nxConfig = await this.files.readOptionalText(root, "nx.json");
    const projectShape = nxConfig === null && isSupportedRootProject(packageJson, angular) ? "root-angular-cli" : "unsupported-layout";
    const git = await this.readGitSnapshot(root);
    const npmrc = await this.files.readOptionalText(root, ".npmrc");
    const fingerprint = await fingerprintInputs(
      root,
      this.files,
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      git.fingerprint
    );
    const registry = validateRegistryTrust(
      npmrc ?? "",
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      declarations.some((item) => item.name.startsWith("@ips/"))
    );
    const registryStatus = registry.trusted ? "trusted" : "untrusted";
    const dependencySourcesStatus = declarations.every((item) => item.safe) ? "safe" : "unsafe";
    const nodeRanges = [];
    const npmRanges = [];
    readDeclaredRanges(packageJson, nodeRanges, npmRanges, issues);
    for (const relative of [".nvmrc", ".node-version"]) {
      const text = await this.files.readOptionalText(root, relative);
      if (text?.trim())
        addRange(text.trim().replace(/^v(?=\d)/, ""), nodeRanges, issues);
    }
    const toolVersions = await this.files.readOptionalText(
      root,
      ".tool-versions"
    );
    const nodeToolVersion = /^\s*nodejs\s+(\S+)/m.exec(toolVersions ?? "")?.[1];
    if (nodeToolVersion)
      addRange(nodeToolVersion.replace(/^v(?=\d)/, ""), nodeRanges, issues);
    const packageManager = typeof packageJson.packageManager === "string" ? packageJson.packageManager : "npm";
    const npmPin = /^npm@(.+)$/.exec(packageManager)?.[1];
    if (npmPin) addRange(npmPin, npmRanges, issues);
    const npmRange = [lockfileVersion === 1 ? ">=5" : ">=7", ...npmRanges].join(
      " "
    );
    const fnm = await resolveWindowsExecutable("fnm", this.options.environment);
    const runtimeCandidates = fnm ? await this.readRuntimeCandidates(fnm, root, nodeRanges, npmRange) : [];
    const installedCandidates = runtimeCandidates.filter(
      (candidate) => candidate.status === "installed"
    );
    const metadataRuntime = planRuntime({
      nodeRanges: [],
      npmRange,
      candidates: installedCandidates
    }).selected;
    let packages = [];
    if (registryStatus === "trusted" && dependencySourcesStatus === "safe") {
      if (metadataRuntime && fnm) {
        packages = await this.readTargetPackageMetadata(
          root,
          fnm,
          metadataRuntime.nodeVersion,
          declarations,
          facts.angularMajor,
          targetMajor,
          issues
        );
      } else {
        issues.push({
          code: "runtime_metadata_unavailable",
          message: "No installed exact Node runtime can run read-only npm metadata queries."
        });
      }
    }
    const checkRecords = createChecks(scripts, Boolean(lockfileVersion));
    const input = {
      projectId: facts.projectId,
      inputFingerprint: fingerprint,
      sourceMajor: facts.angularMajor,
      projectShape,
      packageManager,
      lockfileVersion,
      gitStatus: git.status,
      registryStatus,
      dependencySourcesStatus,
      nodeRanges,
      npmRange,
      runtimeCandidates,
      metadataRuntimeVersion: metadataRuntime?.nodeVersion ?? null,
      checks: checkRecords,
      packages,
      registryIdentities: registry.identities,
      issues: [
        ...issues,
        ...fnm ? [] : [
          {
            code: "fnm_missing",
            message: "fnm is required for runtime planning."
          }
        ]
      ]
    };
    return input;
  }
  async readFingerprint(projectRoot) {
    const root = await this.files.canonicalProjectRoot(projectRoot);
    const git = await this.readGitSnapshot(root);
    return fingerprintInputs(
      root,
      this.files,
      this.options.environment.MIGRATION_IPS_REGISTRY ?? "",
      git.fingerprint
    );
  }
  async readGitSnapshot(root) {
    const git = await resolveWindowsExecutable("git", this.options.environment);
    if (!git) return { status: "unavailable", fingerprint: "git-unavailable" };
    const prefix = await this.runHostCommand(
      git,
      ["rev-parse", "--show-prefix"],
      root,
      1e4
    );
    if (!successful(prefix) || prefix.stdout.trim() !== "")
      return { status: "unavailable", fingerprint: "git-root-unavailable" };
    const head = await this.runHostCommand(
      git,
      ["rev-parse", "--verify", "HEAD"],
      root,
      1e4
    );
    if (!successful(head) || !/^[a-f0-9]{40,64}$/i.test(head.stdout.trim()))
      return { status: "unavailable", fingerprint: "git-head-unavailable" };
    const status = await this.runHostCommand(
      git,
      [
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        ".",
        ":!.angular-migration"
      ],
      root,
      3e4
    );
    if (!successful(status))
      return { status: "unavailable", fingerprint: "git-status-unavailable" };
    return {
      status: status.stdout.trim().length === 0 ? "clean" : "dirty",
      fingerprint: `${head.stdout.trim()}\0${status.stdout}`
    };
  }
  async readRuntimeCandidates(fnm, root, nodeRanges, npmRange) {
    const list = await this.runHostCommand(fnm, ["list"], root, 3e4);
    const versions = successful(list) ? parseFnmVersions(list.stdout) : [];
    const installed = [];
    for (const nodeVersion of versions) {
      const node = await this.runRuntimeCommand({
        fnmExecutable: fnm,
        nodeVersion,
        executable: "node",
        arguments: ["--version"],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 3e4,
        terminationGraceMs: 5e3,
        maxOutputBytes: 8192
      });
      const npm = await this.runNpmCommand({
        fnmExecutable: fnm,
        nodeVersion,
        arguments: ["--version"],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 3e4,
        terminationGraceMs: 5e3,
        maxOutputBytes: 8192
      });
      const actualNode = parseExactSemverVersion(
        node.stdout.trim().replace(/^v/, "")
      );
      const actualNpm = parseExactSemverVersion(
        npm.stdout.trim().replace(/^v/, "")
      );
      if (successful(node) && successful(npm) && actualNode?.version === nodeVersion && actualNpm) {
        installed.push({
          nodeVersion,
          npmVersion: actualNpm.version,
          status: "installed"
        });
      }
    }
    const installedPlan = planRuntime({
      nodeRanges,
      npmRange,
      candidates: installed
    });
    if (installedPlan.status === "ready") return installed;
    const remotePlanRange = nodeRanges.length > 0 ? nodeRanges.join(" ") : "*";
    const fnmRemote = await this.runHostCommand(
      fnm,
      ["list-remote", "--latest", "--filter", remotePlanRange],
      root,
      6e4
    );
    if (!successful(fnmRemote)) return installed;
    const remoteVersion = parseFnmVersions(fnmRemote.stdout)[0];
    if (!remoteVersion || installed.some(({ nodeVersion }) => nodeVersion === remoteVersion))
      return installed;
    return [
      ...installed,
      { nodeVersion: remoteVersion, npmVersion: null, status: "missing" }
    ];
  }
  async readTargetPackageMetadata(root, fnm, nodeVersion, declarations, sourceMajor, targetMajor, issues) {
    const relevant = declarations.filter(
      ({ name }) => isAngularMigrationPackage(name)
    );
    if (!relevant.some(({ name }) => name === "@angular/core")) return [];
    const resolved = [];
    for (const dependency of relevant) {
      const selector = getTargetSelector(dependency.name, targetMajor);
      const result = await this.runNpmCommand({
        fnmExecutable: fnm,
        nodeVersion,
        arguments: [
          "view",
          `${dependency.name}@${selector}`,
          "version",
          "engines",
          "peerDependencies",
          "deprecated",
          "--json"
        ],
        cwd: root,
        env: { ...this.options.environment },
        timeoutMs: 12e4,
        terminationGraceMs: 5e3,
        maxOutputBytes: 262144
      });
      if (!successful(result)) {
        issues.push({
          code: "registry_metadata_unavailable",
          message: `Registry metadata for ${dependency.name} is unavailable.`
        });
        continue;
      }
      const candidates = parseNpmCandidates(result.stdout, selector);
      if (candidates.length === 0) {
        issues.push({
          code: "registry_metadata_invalid",
          message: `Registry metadata for ${dependency.name} has no stable compatible version.`
        });
        continue;
      }
      const candidate = candidates[0];
      if (candidate.nodeRange && !isValidSemverRange(candidate.nodeRange)) {
        issues.push({
          code: "registry_metadata_invalid",
          message: `Registry metadata for ${dependency.name} contains an invalid Node engine range.`
        });
        continue;
      }
      if (dependency.name.startsWith("@angular/") && !dependency.name.startsWith("@angular-devkit/") && dependency.name !== "@angular/cli" && candidate.major !== targetMajor) {
        issues.push({
          code: "angular_package_major_mismatch",
          message: `Registry metadata for ${dependency.name} does not match target Angular ${targetMajor}.`
        });
        continue;
      }
      const toolingPackage = dependency.name.startsWith("@angular-devkit/") || dependency.name.startsWith("@ngtools/");
      if (!toolingPackage && dependency.sourceVersionMajor !== sourceMajor) {
        issues.push({
          code: "angular_source_major_mismatch",
          message: `Locked ${dependency.name} does not match the detected Angular source major.`
        });
        continue;
      }
      resolved.push({
        name: dependency.name,
        sourceVersion: dependency.sourceVersion,
        targetVersion: candidate.version,
        registryId: dependency.name.startsWith("@ips/") ? "ips-private" : "npmjs",
        nodeRange: candidate.nodeRange,
        peerDependencies: candidate.peerDependencies,
        reason: `highest-stable-version-matching-${selector}`
      });
    }
    return resolved.sort((left, right) => left.name.localeCompare(right.name));
  }
  runHostCommand(executable, arguments_, cwd, timeoutMs) {
    return this.runCommand({
      executable,
      arguments: arguments_,
      cwd,
      env: { ...this.options.environment },
      timeoutMs,
      terminationGraceMs: 5e3,
      maxOutputBytes: 262144
    });
  }
};
function readDependencies(packageJson, lockfile) {
  const lockfileVersion = lockfile.lockfileVersion;
  const lockEntries = asRecord3(
    lockfileVersion === 1 ? lockfile.dependencies : lockfile.packages
  );
  const declarations = [];
  const seen = /* @__PURE__ */ new Set();
  for (const sectionName of SECTIONS) {
    const section = packageJson[sectionName];
    if (section === void 0) continue;
    const entries = asRecord3(section);
    for (const [name, specification] of Object.entries(entries)) {
      const duplicate = seen.has(name);
      seen.add(name);
      const lockedEntry = asRecordOrEmpty(
        lockfileVersion === 1 ? lockEntries[name] : lockEntries[`node_modules/${name}`]
      );
      const locked = typeof lockedEntry.version === "string" ? parseExactSemverVersion(lockedEntry.version) : null;
      const range = typeof specification === "string" ? specification : null;
      const safe = Boolean(
        !duplicate && range && isValidSemverRange(range) && locked && satisfiesAllSemverRanges(locked.version, [range])
      );
      if (safe && locked) {
        declarations.push({
          name,
          sourceVersion: locked.version,
          sourceVersionMajor: locked.major,
          safe
        });
      } else {
        declarations.push({
          name,
          sourceVersion: locked?.version ?? "0.0.0",
          sourceVersionMajor: locked?.major ?? 0,
          safe: false
        });
      }
    }
  }
  return declarations;
}
function isSupportedRootProject(packageJson, angular) {
  if (Object.hasOwn(packageJson, "workspaces")) return false;
  const projects = asRecordOrEmpty(angular.projects);
  const applications = Object.values(projects).filter((project) => {
    const record = asRecordOrEmpty(project);
    return record.projectType === "application" && (record.root === void 0 || record.root === "" || record.root === ".");
  });
  return applications.length > 0;
}
function readDeclaredRanges(packageJson, nodeRanges, npmRanges, issues) {
  const engines = asRecordOrEmpty(packageJson.engines);
  const volta = asRecordOrEmpty(packageJson.volta);
  for (const range of [engines.node, volta.node])
    if (range !== void 0) addRange(range, nodeRanges, issues);
  for (const range of [engines.npm, volta.npm])
    if (range !== void 0) addRange(range, npmRanges, issues);
}
function addRange(value, ranges, issues) {
  if (typeof value !== "string" || !isValidSemverRange(value)) {
    issues.push({
      code: "unsupported_runtime_range",
      message: "A declared Node or npm version range is invalid or unsupported."
    });
    return;
  }
  ranges.push(value);
}
function createChecks(scripts, hasLockfile) {
  const definitions = [
    ["typecheck", ["typecheck", "type-check", "check:types", "tsc"]],
    ["lint", ["lint"]],
    ["unit-test", ["test:unit", "unit-test", "test"]],
    ["build", ["build"]],
    ["e2e", ["e2e", "test:e2e", "cy:run"]]
  ];
  const checks = [
    {
      id: "install",
      status: hasLockfile ? "configured" : "blocked",
      executable: "npm",
      arguments: ["ci"],
      reason: hasLockfile ? null : "package-lock.json is required."
    },
    {
      id: "dependency-tree",
      status: hasLockfile ? "configured" : "blocked",
      executable: "npm",
      arguments: ["ls", "--all"],
      reason: hasLockfile ? null : "package-lock.json is required."
    }
  ];
  for (const [id, names] of definitions) {
    const scriptName = names.find((name) => typeof scripts[name] === "string");
    const status = scriptName ? "configured" : id === "build" ? "blocked" : "not-configured";
    checks.push({
      id,
      status,
      executable: scriptName ? "npm" : null,
      arguments: scriptName ? ["run", scriptName] : [],
      reason: scriptName ? null : id === "build" ? "An Angular application must define an npm build script." : "No matching npm script was found."
    });
  }
  return checks;
}
function validateRegistryTrust(npmrc, trustedIpsValue, hasPrivateDependencies) {
  const registryEntries = /* @__PURE__ */ new Map();
  let trusted = true;
  for (const rawLine of npmrc.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const credential = /(?:_authToken|_auth|password)\s*=\s*([^\s#;]+)/i.exec(
      line
    );
    if (credential && !/^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/.test(credential[1])) {
      trusted = false;
    }
    const match = /^(@[a-z0-9._-]+:)?registry\s*=\s*(\S+)$/i.exec(line);
    if (match) {
      const scope = match[1] ? `${match[1].slice(0, -1).toLowerCase()}:registry` : "default";
      registryEntries.set(scope, match[2]);
    }
  }
  const identities = /* @__PURE__ */ new Map([["default", "npmjs"]]);
  for (const [scope, value] of registryEntries) {
    const parsed = safeRegistryUrl(value);
    let registryId = "untrusted";
    if (scope === "default") {
      if (parsed?.href !== "https://registry.npmjs.org/") trusted = false;
    } else if (scope === "@ips:registry") {
      if (matchesTrustedIpsRegistry(value, trustedIpsValue)) {
        registryId = "ips-private";
      } else {
        trusted = false;
      }
    } else {
      trusted = false;
    }
    identities.set(
      scope === "default" ? "default" : scope.replace(/:registry$/, ""),
      registryId
    );
  }
  if (hasPrivateDependencies) {
    const configured = registryEntries.get("@ips:registry");
    if (!configured || !matchesTrustedIpsRegistry(configured, trustedIpsValue)) {
      trusted = false;
      identities.set("@ips", "untrusted");
    }
  }
  return {
    trusted,
    identities: [...identities.entries()].map(([scope, registryId]) => ({ scope, registryId })).sort((left, right) => left.scope.localeCompare(right.scope))
  };
}
function matchesTrustedIpsRegistry(configured, trusted) {
  const configuredUrl = safeRegistryUrl(configured);
  const trustedUrl = safeRegistryUrl(trusted);
  return Boolean(
    configuredUrl && trustedUrl && configuredUrl.hostname !== "registry.npmjs.org" && configuredUrl.href.replace(/\/+$/, "") === trustedUrl.href.replace(/\/+$/, "")
  );
}
function safeRegistryUrl(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}
function isAngularMigrationPackage(name) {
  if (name.startsWith("@angular-devkit/") || name.startsWith("@ngtools/"))
    return true;
  if (name === "@angular/cli") return true;
  return name.startsWith("@angular/") && FRAMEWORK_PACKAGES.has(name.slice("@angular/".length));
}
function getTargetSelector(name, targetMajor) {
  if (name.startsWith("@angular-devkit/") || name.startsWith("@ngtools/")) {
    if (targetMajor === 6) return ">=0.6.0 <0.7.0";
    if (targetMajor === 7) return ">=0.10.0 <0.14.0";
    return `>=0.${targetMajor}00.0 <0.${targetMajor + 1}00.0`;
  }
  return `${targetMajor}.x`;
}
function parseNpmCandidates(value, range) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    return [];
  }
  const values = Array.isArray(parsed) ? parsed : [parsed];
  const candidates = [];
  for (const item of values) {
    const record = asRecordOrEmpty(item);
    const version = parseExactSemverVersion(record.version);
    if (!version || (0, import_semver3.prerelease)(version.version) !== null || record.deprecated || !satisfiesAllSemverRanges(version.version, [range])) {
      continue;
    }
    const engines = asRecordOrEmpty(record.engines);
    const peerDependencies = Object.entries(
      asRecordOrEmpty(record.peerDependencies)
    ).map(([name, peerRange]) => ({ name, range: peerRange }));
    if (peerDependencies.some(
      ({ name, range: range2 }) => !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name) || !isValidSemverRange(range2)
    )) {
      continue;
    }
    candidates.push({
      version: version.version,
      major: version.major,
      nodeRange: typeof engines.node === "string" ? engines.node : null,
      peerDependencies
    });
  }
  return candidates.sort((left, right) => (0, import_semver3.compare)(right.version, left.version));
}
function parseFnmVersions(text) {
  const versions = /* @__PURE__ */ new Set();
  for (const line of text.split(/\r?\n/)) {
    const match = /^\s*(?:\*\s*)?v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:\s|$)/.exec(
      line
    );
    if (match && parseExactSemverVersion(match[1])) versions.add(match[1]);
  }
  return [...versions].sort((left, right) => (0, import_semver3.compare)(right, left));
}
async function resolveWindowsExecutable(name, environment) {
  const searchPath = environment.PATH ?? environment.Path ?? "";
  const extensions = (environment.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean);
  for (const directory of searchPath.split(path5.win32.delimiter).filter(Boolean)) {
    for (const extension of extensions) {
      const candidate = path5.win32.join(
        directory,
        `${name}${extension.toLowerCase()}`
      );
      try {
        if ((await fs4.stat(candidate)).isFile()) return candidate;
      } catch {
        continue;
      }
    }
  }
  return null;
}
async function fingerprintInputs(root, files, trustedRegistry, gitFingerprint) {
  const hash = createHash5("sha256");
  for (const relative of FINGERPRINT_FILES) {
    const content = await files.readOptionalText(root, relative);
    hash.update(relative).update("\0").update(content === null ? "missing" : "present");
    hash.update("\0").update(content ?? "").update("\0");
  }
  hash.update("trusted-registry\0").update(trustedRegistry).update("\0");
  hash.update("git-snapshot\0").update(gitFingerprint).update("\0");
  return `sha256:${hash.digest("hex")}`;
}
function successful(result) {
  return result.kind === "exited" && result.exitCode === 0 && !result.stdoutTruncated && !result.stderrTruncated;
}
function asRecord3(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new InfrastructureError(
      "project_facts_invalid",
      "Project metadata has an invalid object shape."
    );
  }
  return value;
}
function asRecordOrEmpty(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

// infrastructure/project-lock.ts
import { randomUUID } from "node:crypto";
var LOCK_PATH = ".angular-migration/discovery.lock";
var ProjectLock = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async acquire(projectRoot) {
    const ownerToken = randomUUID();
    const record = {
      schemaVersion: 1,
      ownerPid: process.pid,
      ownerToken
    };
    let created;
    try {
      created = await this.files.createExclusiveFile(
        projectRoot,
        LOCK_PATH,
        JSON.stringify(record)
      );
    } catch {
      return { kind: "recovery-required" };
    }
    if (!created.created) return { kind: "contended" };
    try {
      const persisted = await this.files.readJson(projectRoot, LOCK_PATH);
      if (!isLockRecord(persisted) || persisted.ownerToken !== ownerToken || persisted.ownerPid !== process.pid) {
        return { kind: "recovery-required" };
      }
    } catch {
      return { kind: "recovery-required" };
    }
    let released = false;
    return {
      kind: "acquired",
      release: async () => {
        if (released) return { kind: "released" };
        let persisted;
        try {
          persisted = await this.files.readJson(projectRoot, LOCK_PATH);
        } catch {
          return { kind: "recovery-required" };
        }
        if (!isLockRecord(persisted) || persisted.ownerToken !== ownerToken || persisted.ownerPid !== process.pid) {
          return { kind: "ownership-lost" };
        }
        try {
          released = await this.files.removeIfIdentityMatches(
            projectRoot,
            LOCK_PATH,
            created.identity
          );
          return released ? { kind: "released" } : { kind: "ownership-lost" };
        } catch {
          return { kind: "recovery-required" };
        }
      }
    };
  }
};
function isLockRecord(value) {
  return Boolean(
    value && typeof value === "object" && "schemaVersion" in value && value.schemaVersion === 1 && "ownerPid" in value && typeof value.ownerPid === "number" && Number.isSafeInteger(value.ownerPid) && value.ownerPid > 0 && "ownerToken" in value && typeof value.ownerToken === "string" && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.ownerToken)
  );
}

// infrastructure/repair-files.ts
var SafeRepairPatchWriter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async apply(projectRoot, patches) {
    const originals = [];
    for (const patch of patches) {
      assertRepairPath(patch.path);
      originals.push({
        path: patch.path,
        content: await this.files.readText(projectRoot, patch.path)
      });
    }
    const applied = [];
    try {
      for (const patch of patches) {
        await this.files.writeAtomically(
          projectRoot,
          patch.path,
          patch.content
        );
        applied.push(patch);
      }
    } catch {
      await rollbackFiles(this.files, projectRoot, applied, originals);
      throw new InfrastructureError(
        "repair_patch_failed",
        "Repair patches could not be applied safely."
      );
    }
    return {
      rollback: () => rollbackFiles(this.files, projectRoot, applied, originals)
    };
  }
};
async function rollbackFiles(files, projectRoot, applied, originals) {
  for (const patch of [...applied].reverse()) {
    const original = originals.find((item) => item.path === patch.path);
    if (!original) throw rollbackError();
    const current = await files.readText(projectRoot, patch.path).catch(() => null);
    if (current !== patch.content) throw rollbackError();
    await files.writeAtomically(projectRoot, patch.path, original.content);
  }
}
function assertRepairPath(relativePath) {
  if (typeof relativePath !== "string" || !/^src\/[A-Za-z0-9._/-]+$/.test(relativePath) || relativePath.split("/").includes("..") || relativePath.includes("\\")) {
    throw new InfrastructureError(
      "project_path_invalid",
      "Repair can only target a safe path under src/."
    );
  }
}
function rollbackError() {
  return new InfrastructureError(
    "repair_rollback_unconfirmed",
    "Repair rollback could not be verified safely."
  );
}

// infrastructure/repair-submission-store.ts
var RepairSubmissionStoreAdapter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async read(projectRoot, runId) {
    if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(runId)) {
      throw new InfrastructureError(
        "repair_submission_invalid",
        "The repair inbox run id is invalid."
      );
    }
    const path7 = `.angular-migration/repair-inbox/${runId}.json`;
    const text = await this.files.readOptionalText(projectRoot, path7);
    if (text === null) {
      throw new InfrastructureError(
        "repair_submission_missing",
        "No controller-owned repair submission is available."
      );
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new InfrastructureError(
        "repair_submission_invalid",
        "The repair submission contains invalid JSON."
      );
    }
  }
};

// infrastructure/run-id-generator.ts
import { randomUUID as randomUUID2 } from "node:crypto";
var CryptoRunIdGenerator = class {
  create() {
    return randomUUID2();
  }
};

// infrastructure/run-operation-executor.ts
import { createHash as createHash6 } from "node:crypto";
var RunOperationExecutorAdapter = class {
  constructor(options) {
    this.options = options;
    this.files = options.files ?? new ProjectFileSystem();
    this.runRuntime = options.runRuntime ?? ((request) => runWithProjectRuntime(request));
    this.runNpm = options.runNpm ?? ((request) => runWithProjectNpm(request, this.runRuntime));
  }
  options;
  files;
  runRuntime;
  runNpm;
  async execute(projectRoot, operation) {
    if (!isValidOperation(operation)) {
      return blocked6("operation_invalid", "The planned operation is invalid.");
    }
    if (operation.kind === "verify-plan") {
      return operation.packages.some(({ name }) => name === "@angular/core") && operation.packages.some(({ name }) => name === "@angular/cli") ? { outcome: "passed" } : blocked6(
        "plan_incomplete",
        "The discovery plan lacks exact Angular core or CLI metadata."
      );
    }
    if (operation.kind === "pin-packages") {
      return this.pinPackages(projectRoot, operation.packages);
    }
    let packageMetadataBefore = null;
    if (operation.postcondition === "package-metadata-stable") {
      try {
        packageMetadataBefore = await this.packageMetadataHash(projectRoot);
      } catch {
        return blocked6(
          "project_metadata_unavailable",
          "Project package metadata could not be read safely."
        );
      }
    }
    const runtimeRequest = {
      fnmExecutable: this.options.fnmExecutable,
      nodeVersion: operation.nodeVersion,
      executable: operation.executable,
      arguments: operation.arguments,
      cwd: await this.files.canonicalProjectRoot(projectRoot),
      env: { ...this.options.environment },
      timeoutMs: operation.timeoutMs,
      terminationGraceMs: 5e3,
      maxOutputBytes: 262144
    };
    const result = operation.executable === "npm" ? await this.runNpm({
      ...runtimeRequest,
      arguments: operation.arguments
    }) : await this.runRuntime(runtimeRequest);
    if (!isSuccessful2(result)) {
      const outcome = result.kind === "spawn-failed" || result.kind === "process-error" || result.kind === "invalid-request" ? "failed" : "blocked";
      return {
        outcome,
        diagnostic: {
          code: processFailureCode(result),
          message: "The project command did not complete successfully."
        }
      };
    }
    try {
      switch (operation.postcondition) {
        case "exit-zero":
          return { outcome: "passed" };
        case "dependency-tree":
          return /\b(?:invalid|extraneous|missing)\b/i.test(
            `${result.stdout}
${result.stderr}`
          ) ? blocked6(
            "dependency_tree_invalid",
            "npm reported an invalid dependency tree."
          ) : { outcome: "passed" };
        case "package-metadata-stable":
          return await this.packageMetadataHash(projectRoot) === packageMetadataBefore ? { outcome: "passed" } : blocked6(
            "package_metadata_changed",
            "npm ci changed package metadata."
          );
        case "target-packages-locked":
          return await hasLockedPackages(
            this.files,
            projectRoot,
            operation.packages
          ) ? { outcome: "passed" } : blocked6(
            "target_lock_mismatch",
            "The lockfile does not contain the planned exact package versions."
          );
        default:
          return blocked6(
            "operation_postcondition_invalid",
            "The process operation has an unsupported postcondition."
          );
      }
    } catch {
      return blocked6(
        "postcondition_unavailable",
        "The operation postcondition could not be verified."
      );
    }
  }
  async pinPackages(projectRoot, packages) {
    try {
      const packageText = await this.files.readText(
        projectRoot,
        "package.json"
      );
      const packageJson = asRecord4(JSON.parse(packageText));
      let changed = false;
      for (const item of packages) {
        const locations = [];
        for (const sectionName of [
          "dependencies",
          "devDependencies",
          "optionalDependencies",
          "peerDependencies"
        ]) {
          const section = packageJson[sectionName];
          if (section && typeof section === "object" && !Array.isArray(section)) {
            const dependencies = section;
            if (Object.hasOwn(dependencies, item.name)) {
              locations.push({ section: dependencies, name: item.name });
            }
          }
        }
        if (locations.length !== 1) {
          return blocked6(
            "dependency_declaration_mismatch",
            "A planned package is not declared exactly once."
          );
        }
        locations[0].section[item.name] = item.targetVersion;
        changed = true;
      }
      if (!changed)
        return blocked6(
          "dependency_plan_empty",
          "No planned packages can be pinned."
        );
      const indent = /(?:^|\n)([\t ]+)"/.exec(packageText)?.[1] ?? "  ";
      const newline = packageText.includes("\r\n") ? "\r\n" : "\n";
      const trailingNewline = /(?:\r?\n)$/.test(packageText) ? newline : "";
      const output = JSON.stringify(packageJson, null, indent).replace(/\n/g, newline) + trailingNewline;
      await this.files.writeAtomically(projectRoot, "package.json", output);
      const verified = asRecord4(
        await this.files.readJson(projectRoot, "package.json")
      );
      return packages.every(
        (item) => hasExactDeclaration(verified, item.name, item.targetVersion)
      ) ? { outcome: "passed" } : blocked6(
        "dependency_pin_unconfirmed",
        "Exact package declarations failed their postcondition."
      );
    } catch {
      return blocked6(
        "dependency_pin_failed",
        "Exact package declarations could not be written safely."
      );
    }
  }
  async packageMetadataHash(projectRoot) {
    const packageText = await this.files.readText(projectRoot, "package.json");
    const lockText = await this.files.readText(
      projectRoot,
      "package-lock.json"
    );
    return createHash6("sha256").update(packageText).update("\0").update(lockText).digest("hex");
  }
};
function isValidOperation(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const operation = value;
  if (typeof operation.id !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(operation.id) || !parseExactSemverVersion(operation.nodeVersion) || !Number.isSafeInteger(operation.timeoutMs) || operation.timeoutMs < 1 || operation.timeoutMs > 6e5 || !Array.isArray(operation.arguments) || operation.arguments.some(
    (argument) => typeof argument !== "string" || /[\0\r\n]/.test(argument)
  ) || !Array.isArray(operation.packages) || operation.packages.some(
    (item) => !item || typeof item.name !== "string" || !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(item.name) || parseExactSemverVersion(item.targetVersion)?.version !== item.targetVersion
  )) {
    return false;
  }
  if (operation.kind === "pin-packages") {
    return operation.stage === "update-dependencies" && operation.executable === null && operation.arguments.length === 0 && operation.postcondition === "target-packages-declared" && operation.packages.length > 0;
  }
  if (operation.kind === "verify-plan") {
    return operation.stage === "resolve" && operation.executable === null && operation.arguments.length === 0 && operation.postcondition === "verify-plan";
  }
  if (operation.kind !== "process" || typeof operation.executable !== "string")
    return false;
  if (operation.id === "angular-core-cli-update") {
    return operation.id === "angular-core-cli-update" && operation.stage === "update-angular" && operation.executable === "npm" && operation.arguments.length === 6 && operation.arguments[0] === "exec" && operation.arguments[1] === "--" && operation.arguments[2] === "ng" && operation.arguments[3] === "update" && operation.arguments[4] === `@angular/core@${operation.packages.find(({ name }) => name === "@angular/core")?.targetVersion}` && operation.arguments[5] === `@angular/cli@${operation.packages.find(({ name }) => name === "@angular/cli")?.targetVersion}` && operation.postcondition === "target-packages-locked";
  }
  if (operation.executable !== "npm") return false;
  const allowed = /* @__PURE__ */ new Map([
    [
      "baseline-install",
      {
        stage: "baseline",
        args: ["ci"],
        postcondition: "package-metadata-stable"
      }
    ],
    [
      "install-clean",
      {
        stage: "install",
        args: ["ci"],
        postcondition: "package-metadata-stable"
      }
    ],
    [
      "baseline-dependency-tree",
      {
        stage: "baseline",
        args: ["ls", "--all"],
        postcondition: "dependency-tree"
      }
    ],
    [
      "install-dependency-tree",
      {
        stage: "install",
        args: ["ls", "--all"],
        postcondition: "dependency-tree"
      }
    ],
    [
      "update-lockfile",
      {
        stage: "update-dependencies",
        args: ["install", "--package-lock-only", "--ignore-scripts"],
        postcondition: "target-packages-locked"
      }
    ]
  ]);
  const fixed = allowed.get(operation.id);
  if (fixed) {
    return operation.stage === fixed.stage && JSON.stringify(operation.arguments) === JSON.stringify(fixed.args) && operation.postcondition === fixed.postcondition;
  }
  return /^(?:validate|baseline)-[a-z][a-z0-9-]{0,63}$/.test(operation.id) && (operation.stage === "validate" || operation.stage === "baseline") && operation.arguments.length === 2 && operation.arguments[0] === "run" && /^[a-zA-Z0-9:_-]+$/.test(operation.arguments[1]) && operation.postcondition === "exit-zero";
}
function isSuccessful2(result) {
  return result.kind === "exited" && result.exitCode === 0 && !result.stdoutTruncated && !result.stderrTruncated;
}
function processFailureCode(result) {
  if (result.kind === "timed-out") return "process_timed_out";
  if (result.kind === "spawn-failed") return "process_spawn_failed";
  if (result.kind === "process-error") return "process_error";
  if (result.kind === "invalid-request") return "process_request_invalid";
  if (result.kind === "exited" && result.exitCode !== 0)
    return "process_nonzero_exit";
  if (result.kind === "signaled") return "process_signaled";
  return "process_output_truncated";
}
function blocked6(code, message) {
  return { outcome: "blocked", diagnostic: { code, message } };
}
async function hasLockedPackages(files, projectRoot, packages) {
  const lockfile = asRecord4(
    await files.readJson(projectRoot, "package-lock.json")
  );
  const version = lockfile.lockfileVersion;
  if (version !== 1 && version !== 2 && version !== 3) return false;
  const entries = asRecord4(
    lockfile[version === 1 ? "dependencies" : "packages"]
  );
  return packages.every((item) => {
    const entry = asRecord4(
      version === 1 ? entries[item.name] : entries[`node_modules/${item.name}`]
    );
    return parseExactSemverVersion(entry.version)?.version === item.targetVersion;
  });
}
function hasExactDeclaration(packageJson, name, targetVersion) {
  const sections = [
    "dependencies",
    "devDependencies",
    "optionalDependencies",
    "peerDependencies"
  ];
  const values = sections.flatMap((section) => {
    const value = packageJson[section];
    if (!value || typeof value !== "object" || Array.isArray(value)) return [];
    const dependencies = value;
    return Object.hasOwn(dependencies, name) ? [dependencies[name]] : [];
  });
  return values.length === 1 && values[0] === targetVersion;
}
function asRecord4(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new InfrastructureError(
      "project_json_invalid",
      "Project metadata has an invalid object shape."
    );
  }
  return value;
}

// infrastructure/run-record-store.ts
var RUN_RECORD_PATH = ".angular-migration/run.json";
var RunRecordStoreAdapter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async read(projectRoot) {
    const text = await this.files.readOptionalText(
      projectRoot,
      RUN_RECORD_PATH
    );
    if (text === null) return null;
    try {
      return JSON.parse(text);
    } catch {
      throw new InfrastructureError(
        "run_record_invalid",
        "The persisted run record contains invalid JSON."
      );
    }
  }
  async write(projectRoot, record) {
    let content;
    try {
      content = `${JSON.stringify(record)}
`;
    } catch {
      throw new InfrastructureError(
        "run_record_invalid",
        "The run record cannot be serialized safely."
      );
    }
    await this.files.writeAtomically(projectRoot, RUN_RECORD_PATH, content);
  }
};

// infrastructure/runtime-install.ts
var AUDIT_PATH = ".angular-migration/runtime-install.json";
var RuntimeInstallAuditStoreAdapter = class {
  constructor(files = new ProjectFileSystem()) {
    this.files = files;
  }
  files;
  async read(projectRoot) {
    const text = await this.files.readOptionalText(projectRoot, AUDIT_PATH);
    if (text === null) return null;
    try {
      return JSON.parse(text);
    } catch {
      throw new InfrastructureError(
        "runtime_install_audit_invalid",
        "Runtime installation audit history contains invalid JSON."
      );
    }
  }
  async write(projectRoot, events) {
    await this.files.writeAtomically(
      projectRoot,
      AUDIT_PATH,
      `${JSON.stringify(events)}
`
    );
  }
};
var FnmExactRuntimeInstaller = class {
  constructor(options) {
    this.options = options;
  }
  options;
  async install(projectRoot, nodeVersion) {
    if (!parseExactSemverVersion(nodeVersion)) return "failed";
    try {
      const files = this.options.files ?? new ProjectFileSystem();
      const result = await (this.options.run ?? runProcess)({
        executable: this.options.fnmExecutable,
        arguments: ["install", nodeVersion],
        cwd: await files.canonicalProjectRoot(projectRoot),
        env: this.options.environment,
        timeoutMs: 6e5,
        terminationGraceMs: 1e4,
        maxOutputBytes: 262144
      });
      return result.kind === "exited" && result.exitCode === 0 ? "installed" : "failed";
    } catch {
      return "failed";
    }
  }
};

// entrypoints/cli.ts
var MAX_CLI_OUTPUT_BYTES = 1048576;
async function dispatchCli(arguments_, useCases) {
  try {
    const request = parseRequest(arguments_);
    const result = await dispatchRequest(request, useCases);
    const status = resultStatus(request, result);
    return response(status, publicData(request, result), null);
  } catch (error) {
    const failure = safeFailure(error);
    return response(failure.status, null, failure.error);
  }
}
function parseRequest(arguments_) {
  if (!Array.isArray(arguments_) || arguments_.length === 0) {
    throw usageError("cli_command_required", "A command is required.");
  }
  const command = arguments_[0];
  if (![
    "inspect",
    "discover",
    "start",
    "approve-runtime",
    "approve-baseline-dependencies",
    "baseline-dependency-context",
    "skip-check",
    "repair-context",
    "record-repair",
    "documentation-research-context",
    "record-documentation-research",
    "documentation-publish-context",
    "publish-documentation",
    "run",
    "status"
  ].includes(command)) {
    throw usageError(
      "cli_command_unknown",
      "The requested command is not supported."
    );
  }
  const values = /* @__PURE__ */ new Map();
  for (let index = 1; index < arguments_.length; index += 1) {
    const option = arguments_[index];
    if (!option.startsWith("--")) {
      throw usageError(
        "cli_option_invalid",
        "CLI options require a name and value."
      );
    }
    const name = option.slice(2);
    if (![
      "project-root",
      "target-major",
      "run-id",
      "plan-hash",
      "proposal-hash",
      "confirmed",
      "check-id",
      "reason"
    ].includes(name)) {
      throw usageError(
        "cli_option_unknown",
        "The requested option is not supported."
      );
    }
    if (index + 1 >= arguments_.length) {
      throw usageError(
        "cli_option_invalid",
        "CLI options require a name and value."
      );
    }
    const value = arguments_[++index];
    if (!value || value.startsWith("--") || values.has(name)) {
      throw usageError(
        "cli_option_invalid",
        "CLI options must have one non-empty value."
      );
    }
    values.set(name, value);
  }
  const projectRoot = values.get("project-root");
  if (!projectRoot) {
    throw usageError(
      "cli_project_root_required",
      "--project-root is required."
    );
  }
  if (["inspect", "status"].includes(command)) {
    if (values.size !== 1) {
      throw usageError(
        "cli_option_unexpected",
        "The command received an unsupported option."
      );
    }
    return { command, projectRoot };
  }
  if (command === "approve-baseline-dependencies") {
    const runId = values.get("run-id");
    const proposalHash = values.get("proposal-hash");
    if (values.size !== 4 || !runId || !proposalHash || !/^sha256:[a-f0-9]{64}$/.test(proposalHash) || values.get("confirmed") !== "true") {
      throw usageError(
        "cli_baseline_approval_invalid",
        "Baseline dependency approval requires a run, proposal hash, and --confirmed true."
      );
    }
    return {
      command,
      projectRoot,
      runId,
      proposalHash,
      confirmed: true
    };
  }
  if (command === "publish-documentation") {
    const runId = values.get("run-id");
    const proposalHash = values.get("proposal-hash");
    if (values.size !== 4 || !runId || !proposalHash || !/^sha256:[a-f0-9]{64}$/.test(proposalHash) || values.get("confirmed") !== "true") {
      throw usageError(
        "cli_documentation_approval_invalid",
        "Documentation publishing requires a run, current proposal hash, and --confirmed true."
      );
    }
    return { command, projectRoot, runId, proposalHash, confirmed: true };
  }
  if ([
    "run",
    "repair-context",
    "record-repair",
    "baseline-dependency-context",
    "documentation-research-context",
    "record-documentation-research",
    "documentation-publish-context"
  ].includes(command)) {
    const runId = values.get("run-id");
    if (values.size !== 2 || !runId) {
      throw usageError(
        "cli_run_id_required",
        "--run-id is required for this command."
      );
    }
    if (command === "run") return { command, projectRoot, runId };
    return { command, projectRoot, runId };
  }
  if (command === "skip-check") {
    const runId = values.get("run-id");
    const checkId = values.get("check-id");
    const reason = values.get("reason");
    if (values.size !== 5 || !runId || !checkId || !reason || reason.length > 2e3 || values.get("confirmed") !== "true") {
      throw usageError(
        "cli_skip_request_invalid",
        "Skipping a check requires run id, check id, reason, and --confirmed true."
      );
    }
    return { command, projectRoot, runId, checkId, reason, confirmed: true };
  }
  const targetText = values.get("target-major");
  if (command === "approve-runtime") {
    const proposalHash = values.get("plan-hash");
    if (values.size !== 4 || !targetText || !/^(?:0|[1-9]\d*)$/.test(targetText) || !Number.isSafeInteger(Number(targetText)) || !proposalHash || !/^sha256:[a-f0-9]{64}$/.test(proposalHash) || values.get("confirmed") !== "true") {
      throw usageError(
        "cli_runtime_approval_invalid",
        "Runtime approval requires a target, current plan hash, and --confirmed true."
      );
    }
    return {
      command,
      projectRoot,
      targetMajor: Number(targetText),
      proposalHash,
      confirmed: true
    };
  }
  if (values.size !== 2 || !targetText || !/^(?:0|[1-9]\d*)$/.test(targetText) || !Number.isSafeInteger(Number(targetText))) {
    throw usageError(
      "cli_target_major_invalid",
      "A valid --target-major is required."
    );
  }
  return {
    command,
    projectRoot,
    targetMajor: Number(targetText)
  };
}
async function dispatchRequest(request, useCases) {
  switch (request.command) {
    case "inspect":
      return useCases.inspect(request.projectRoot);
    case "discover":
      return useCases.discover(request.projectRoot, request.targetMajor);
    case "start":
      return useCases.start(request.projectRoot, request.targetMajor);
    case "approve-runtime":
      return useCases.approveRuntime(
        request.projectRoot,
        request.targetMajor,
        request.proposalHash,
        request.confirmed
      );
    case "baseline-dependency-context":
      return useCases.baselineDependencyContext(
        request.projectRoot,
        request.runId
      );
    case "approve-baseline-dependencies":
      return useCases.approveBaselineDependencies(
        request.projectRoot,
        request.runId,
        request.proposalHash,
        request.confirmed
      );
    case "skip-check":
      return useCases.skipCheck(
        request.projectRoot,
        request.runId,
        request.checkId,
        request.reason,
        request.confirmed
      );
    case "repair-context":
      return useCases.repairContext(request.projectRoot, request.runId);
    case "record-repair":
      return useCases.recordRepair(request.projectRoot, request.runId);
    case "documentation-research-context":
      return useCases.documentationResearchContext(
        request.projectRoot,
        request.runId
      );
    case "record-documentation-research":
      return useCases.recordDocumentationResearch(
        request.projectRoot,
        request.runId
      );
    case "documentation-publish-context":
      return useCases.documentationPublishContext(
        request.projectRoot,
        request.runId
      );
    case "publish-documentation":
      return useCases.publishDocumentation(
        request.projectRoot,
        request.runId,
        request.proposalHash,
        request.confirmed
      );
    case "run":
      return useCases.run(request.projectRoot, request.runId);
    case "status":
      return useCases.status(request.projectRoot);
  }
}
function resultStatus(command, value) {
  if (!isRecord8(value)) return "success";
  if (command.command === "discover") {
    return value.status === "ready" ? "success" : "blocked";
  }
  if (command.command === "status" && value.nextAction === "human-intervention") {
    return "blocked";
  }
  if (command.command === "run" && isRecord8(value.state)) {
    if (value.state.status === "blocked" || value.state.status === "needs-repair") {
      return "blocked";
    }
    if (value.state.status === "failed") return "failed";
  }
  return "success";
}
function publicData(request, value) {
  if ((request.command === "start" || request.command === "run") && isRecord8(value) && isRecord8(value.state)) {
    return {
      runId: value.state.runId,
      status: value.state.status,
      stage: value.state.stage
    };
  }
  return value;
}
function response(status, data, error) {
  const result = {
    schemaVersion: 1,
    ok: status === "success",
    status,
    data,
    error
  };
  let stdout = `${JSON.stringify(result)}
`;
  if (Buffer.byteLength(stdout, "utf8") > MAX_CLI_OUTPUT_BYTES) {
    const bounded = {
      schemaVersion: 1,
      ok: false,
      status: "failed",
      data: null,
      error: {
        code: "cli_output_too_large",
        message: "The response exceeds the supported output limit."
      }
    };
    return {
      response: bounded,
      stdout: `${JSON.stringify(bounded)}
`,
      exitCode: 1
    };
  }
  return {
    response: result,
    stdout,
    exitCode: status === "success" ? 0 : status === "blocked" ? 2 : 1
  };
}
function safeFailure(error) {
  if (error instanceof ApplicationError) {
    return {
      status: error.outcome === "blocked" || isExpectedBlockCode(error.code) ? "blocked" : "failed",
      error: { code: error.code, message: error.message }
    };
  }
  if (isSafeTypedError(error)) {
    return {
      status: isExpectedBlockCode(error.code) ? "blocked" : "failed",
      error: { code: error.code, message: error.message }
    };
  }
  return {
    status: "failed",
    error: {
      code: "internal_error",
      message: "The controller could not complete the request."
    }
  };
}
function isExpectedBlockCode(code) {
  return (/* @__PURE__ */ new Set([
    "start_request_invalid",
    "run_request_invalid",
    "status_request_invalid",
    "non_sequential_angular_major",
    "project_root_invalid",
    "project_path_invalid",
    "project_path_outside_root",
    "project_json_invalid",
    "project_facts_invalid",
    "project_busy",
    "project_recovery_required",
    "discovery_invalid",
    "discovery_integrity_failed",
    "discovery_context_mismatch",
    "discovery_stale",
    "discovery_not_ready",
    "project_not_clean",
    "project_major_mismatch",
    "planned_runtime_unavailable",
    "planned_runtime_invalid",
    "confirmation_required",
    "runtime_approval_request_invalid",
    "runtime_proposal_stale",
    "runtime_install_not_required",
    "runtime_install_already_attempted",
    "runtime_install_recovery_required",
    "runtime_install_audit_invalid",
    "runtime_install_failed",
    "runtime_install_unverified",
    "baseline_dependency_request_invalid",
    "baseline_dependency_context_unavailable",
    "baseline_dependency_context_stale",
    "baseline_dependency_proposal_invalid",
    "baseline_dependency_proposal_stale",
    "baseline_dependency_hash_invalid",
    "baseline_dependency_approval_invalid",
    "baseline_dependency_approval_recovery_required",
    "baseline_dependency_install_failed",
    "baseline_dependency_transition_rejected",
    "skip_request_invalid",
    "critical_check_cannot_be_skipped",
    "check_not_skippable",
    "skip_context_unavailable",
    "skip_transition_rejected",
    "cli_skip_request_invalid",
    "repair_request_invalid",
    "repair_context_unavailable",
    "repair_fingerprint_stale",
    "repair_attempts_exhausted",
    "repair_scope_unknown",
    "repair_submission_invalid",
    "repair_submission_stale",
    "repair_submission_too_large",
    "repair_submission_replayed",
    "repair_verification_failed",
    "repair_transition_rejected",
    "repair_gate_invalid",
    "repair_rollback_unconfirmed",
    "project_context_invalid",
    "project_check_invalid",
    "angular_cli_metadata_missing",
    "run_already_active",
    "run_not_found",
    "run_context_mismatch",
    "run_record_invalid",
    "run_record_integrity_failed",
    "run_record_context_mismatch"
  ])).has(code);
}
function usageError(code, message) {
  return new ApplicationError(code, message, "blocked");
}
function isSafeTypedError(error) {
  return Boolean(
    error instanceof Error && "code" in error && typeof error.code === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(error.code) && error.message.length > 0 && !/[A-Za-z]:\\[^\s]+/.test(error.message) && !/https?:\/\/[^/@\s]+:[^/@\s]+@/.test(error.message)
  );
}
function isRecord8(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

// entrypoints/main.ts
function currentEnvironment() {
  return Object.fromEntries(
    Object.entries(process.env).filter(
      (entry) => typeof entry[1] === "string"
    )
  );
}
async function main() {
  const environment = currentEnvironment();
  const pluginRoot = environment.ANGULAR_MIGRATION_PLUGIN_ROOT ?? path6.resolve(path6.dirname(fileURLToPath(import.meta.url)), "../../..");
  const hookRuntime = new HookRuntimeDeployer(pluginRoot);
  const reader = new ProjectDiscoveryReaderAdapter({ environment });
  const discoveries = new DiscoveryRecordStoreAdapter();
  const runRecords = new RunRecordStoreAdapter();
  const repairSubmissions = new RepairSubmissionStoreAdapter();
  const repairPatches = new SafeRepairPatchWriter();
  const runtimeInstallAudit = new RuntimeInstallAuditStoreAdapter();
  const documentationArtifacts = new DocumentationArtifactStoreAdapter();
  const facts = new ProjectFactsReaderAdapter();
  const lock = new ProjectLock();
  const ids = new CryptoRunIdGenerator();
  const hasher = new ProjectValueHasher();
  const documentationPorts = {
    runs: runRecords,
    lock,
    fingerprints: reader,
    context: {
      readProjectFacts: (root) => facts.readProjectFacts(root),
      readFingerprint: (root) => reader.readFingerprint(root)
    },
    artifacts: documentationArtifacts,
    hasher,
    contentHasher: hasher
  };
  const operations = new RunOperationExecutorAdapter({
    environment,
    fnmExecutable: "fnm"
  });
  const runtimeInstaller = new FnmExactRuntimeInstaller({
    environment,
    fnmExecutable: "fnm"
  });
  const baselineProposalReader = new NpmBaselineDependencyProposalReader({
    environment,
    fnmExecutable: "fnm"
  });
  const baselineDependencyInstaller = new NpmBaselineDependencyInstaller({
    environment,
    fnmExecutable: "fnm"
  });
  const result = await dispatchCli(process.argv.slice(2), {
    inspect: (projectRoot) => inspectProject({ projectRoot }, { facts }),
    discover: (projectRoot, targetMajor) => discoverProject(
      { projectRoot, targetMajor },
      {
        reader,
        records: discoveries,
        hasher
      }
    ),
    approveRuntime: (projectRoot, targetMajor, proposalHash, confirmed) => approveRuntimeInstall(
      { projectRoot, targetMajor, proposalHash, confirmed },
      {
        reader,
        records: discoveries,
        hasher,
        runRecords,
        lock,
        installer: runtimeInstaller,
        audit: runtimeInstallAudit
      }
    ),
    baselineDependencyContext: (projectRoot, runId) => getBaselineDependencyContext(
      { projectRoot, runId },
      {
        records: runRecords,
        lock,
        fingerprints: reader,
        proposals: baselineProposalReader,
        installer: baselineDependencyInstaller,
        hasher
      }
    ),
    approveBaselineDependencies: (projectRoot, runId, proposalHash, confirmed) => approveBaselineDependencies(
      { projectRoot, runId, proposalHash, confirmed },
      {
        records: runRecords,
        lock,
        fingerprints: reader,
        proposals: baselineProposalReader,
        installer: baselineDependencyInstaller,
        hasher
      }
    ),
    skipCheck: (projectRoot, runId, checkId, reason, confirmed) => approveCheckSkip(
      { projectRoot, runId, checkId, reason, confirmed },
      { records: runRecords, lock, fingerprints: reader, hasher }
    ),
    repairContext: (projectRoot, runId) => getRepairContext(
      { projectRoot, runId },
      {
        records: runRecords,
        lock,
        fingerprints: reader,
        operations,
        patches: repairPatches,
        hasher
      }
    ),
    recordRepair: async (projectRoot, runId) => recordRepair(
      {
        projectRoot,
        runId,
        submission: await repairSubmissions.read(projectRoot, runId)
      },
      {
        records: runRecords,
        lock,
        fingerprints: reader,
        operations,
        patches: repairPatches,
        hasher
      }
    ),
    documentationResearchContext: (projectRoot, runId) => getDocumentationResearchContext(
      { projectRoot, runId },
      documentationPorts
    ),
    recordDocumentationResearch: (projectRoot, runId) => recordDocumentationResearch({ projectRoot, runId }, documentationPorts),
    documentationPublishContext: (projectRoot, runId) => getDocumentationPublishContext(
      { projectRoot, runId },
      documentationPorts
    ),
    publishDocumentation: (projectRoot, runId, proposalHash, confirmed) => publishDocumentation(
      { projectRoot, runId, proposalHash, confirmed },
      documentationPorts
    ),
    start: (projectRoot, targetMajor) => startRun(
      { projectRoot, targetMajor },
      {
        reader,
        discoveries,
        runRecords,
        lock,
        ids,
        hasher,
        hookRuntime
      }
    ),
    run: (projectRoot, runId) => runProject(
      { projectRoot, runId },
      {
        records: runRecords,
        lock,
        facts,
        fingerprints: reader,
        operations,
        hasher
      }
    ),
    status: (projectRoot) => getRunStatus(
      { projectRoot },
      {
        records: runRecords,
        context: {
          readProjectFacts: (root) => facts.readProjectFacts(root),
          readFingerprint: (root) => reader.readFingerprint(root)
        },
        hasher
      }
    )
  });
  process.stdout.write(result.stdout);
  process.exitCode = result.exitCode;
}
void main();
