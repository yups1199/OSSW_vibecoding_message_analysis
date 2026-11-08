window.addEventListener('DOMContentLoaded', () => {
  window.ui = SwaggerUIBundle({
    url: '/openapi.json', dom_id: '#swagger-ui',
    presets: [SwaggerUIBundle.presets.apis],
    validatorUrl: null, persistAuthorization: false,
    supportedSubmitMethods: ['get', 'post'],
  });
});
