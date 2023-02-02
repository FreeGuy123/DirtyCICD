# DirtyCICD
Quick and dirty CICD edgecase

I found myself in a position where I was developing containerize powershell apps and the traditional Azure Devops just seems to slow for rapid testing of changes.

My setup is as follows:

AKS Cluster (UserManagedIdenity has Admin Access to cluster)

Azure Container Registry

VM (W2019) with a User Managed Identity and the correct levels of access granted (I could in theory just use myself but I don't want to deal with interactive prompts)

Docker, powershell 7, .net 6 installed

Health Probes built into my image, needing 3 replicas

What it does:

Verifies Docker is running and if not started starts it; it likes to not start or stop randomly for me

Builds your current image based on your docker file

Gets Tokens for Azure

Enables Local Admin and Tags you as the enabler on your container registry

Cycles Password 1 and 2

Uploads Build via Docker

Logs out of Registry

Cycles passwords again and disables Local Admin

Deletes Current AKS Namespace

Creates new namespace and deployment

Has quasi-async ability's when working with aks

All feed back is welcome and encouraged. If you think some or all of it fits your needs feel free to copy away. No ChatGPT was used in the making of this script.
