# GCP Cloud Run Deployment Script
# Make sure you have installed the Google Cloud CLI (gcloud) and have run `gcloud auth login`

Write-Host "Starting deployment to Google Cloud Run..." -ForegroundColor Cyan

# The name of your service on Cloud Run
$SERVICE_NAME = "treecon-spatial-api"

# The region you want to deploy to (e.g., asia-southeast1 for Singapore/Philippines, or us-central1)
$REGION = "asia-southeast1"

# Deploy command
# --source . tells Cloud Build to read the Dockerfile in the current directory and build it in the cloud.
# --allow-unauthenticated makes the API accessible to the public (required since Flutter web runs on client devices).
gcloud run deploy $SERVICE_NAME `
    --source . `
    --region $REGION `
    --allow-unauthenticated `
    --memory 2Gi `
    --cpu 1

Write-Host "Deployment finished!" -ForegroundColor Green
Write-Host "Please copy the Service URL provided in the output above and update your Flutter app." -ForegroundColor Yellow
