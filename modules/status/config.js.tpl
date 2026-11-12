// Shell configuration for the status page. The bot's status command hands out
// a link to /signin, which stores the token under tokenKey.
window.STATUS_CONFIG = {
  pathPrefix: '/status',
  title: 'naju status',
  authHeader: ${jsonencode(auth_header)},
  tokenKey: ${jsonencode(token_key)},
  signInUrl: '/signin',
  disabledPanels: [],
};
