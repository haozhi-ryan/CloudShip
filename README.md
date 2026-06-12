This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.

## Cheat Sheet for Dockerfile
1. Choose base environment (Node)
2. Set working directory
3. Copy dependency files
4. Install dependencies
5. Copy source code
6. Build app
7. Run app

## Build and Run Docker Image
Inside your project:
```bash
docker build -t my-next-app .
```

Then:
```bash
docker run -p 3000:3000 cloudship-app-v1
```

Open:
```bash
http://localhost:3000
```
## Common Docker Commands
View all images 
```bash
docker images
```

View all containers
```bash
docker ps -a
```
Stop a Container
```bash
docker stop <container_name_or_id>
```

Delete container or image
```bash
docker rm -a <container_id_or_name>
```

Building an image with a tag
```bash
docker build -t my-app:v1 .
```

Adding a tag to an existing image
```bash
my-app:v1
```

Follow tags are excluded from immutability in ECR
```bash
latest 
dev 
prod
```

## Check AWS CLI Configuration is correct
```bash
aws configure list
aws sts get-caller-identity
aws s3 ls   # if you have S3 access
```

## Terraform resources
```bash
aws_instance
aws_vpc
aws_subnet
aws_security_group
aws_internet_gateway
aws_route_table
aws_iam_role
aws_s3_bucket
aws_ecr_repository
aws_eks_cluster
```