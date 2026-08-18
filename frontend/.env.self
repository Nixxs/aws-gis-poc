VITE_PMTILES_BASE_URL=https://d24grw4hntc732.cloudfront.net/public/pmtiles/
VITE_QUERY_API_URL=https://xwcbfdedow5kqa2roja44nzmle0zqfvn.lambda-url.ap-southeast-2.on.aws/

# in dev enviornment this falls back to the public/config.json in the frontend, but in prod it points at the hosted config.json in the app bucket
VITE_CONFIG_URL=https://gis-poc-app-intelligis.s3.ap-southeast-2.amazonaws.com/config.json

# Static-app deploy targets (read by deploy-frontend.ps1, not by Vite)
WEB_BUCKET=gis-poc-web-intelligis
WEB_COMMENT=gis-poc-web
WEB_OAC_NAME=gis-poc-web-oac

# App-data CloudFront (pmtiles delivery) - read by deploy-app-cdn.ps1, not by Vite
APP_BUCKET=gis-poc-app-intelligis
APP_CDN_COMMENT=gis-poc-app-cdn
