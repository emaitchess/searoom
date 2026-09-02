// Conventional Commits, enforced locally by .githooks/commit-msg.
//
// Enable once per clone, in this repository:
//
//     git config core.hooksPath .githooks
//
// The hook is not installed automatically. A fresh clone lints nothing until
// that config is set, so treat it as a drafting aid rather than a guarantee.
//
// The two length limits are tighter than commitlint's defaults (100 and 100)
// because they follow what this repository already does: no subject has ever
// exceeded 67 characters and bodies have always wrapped at 80.
module.exports = {
    extends: ['@commitlint/config-conventional'],
    rules: {
        'header-max-length': [2, 'always', 72],
        'body-max-line-length': [2, 'always', 80],
        // Trailers carry URLs that cannot be wrapped: Claude-Session, issue
        // links, Co-authored-by addresses. Length is not meaningful there.
        'footer-max-line-length': [0, 'always', Infinity],
    },
};
