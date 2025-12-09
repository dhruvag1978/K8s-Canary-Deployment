#!/bin/bash

echo "Building simple canary app images..."

# Build v1.0 (stable)
echo "Building v1.0 (stable version)..."
docker build -t simple-canary-app:v1.0 ./app

# Build v2.0 (canary) - same code, different version env
echo "Building v2.0 (canary version)..."
docker build -t simple-canary-app:v2.0 ./app

echo "Images built successfully!"
echo "Available images:"
docker images | grep simple-canary-app