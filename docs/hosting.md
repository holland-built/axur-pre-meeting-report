# Putting the guide on Dokploy (no git repo needed)

Dokploy at http://192.168.100.15:3000

1. Projects, Create Project. Name it `sales-tools`. Keep it out of `wayfinder`,
   so deploying one never disturbs the other.
2. Inside it: Create Service, type **Application**.
3. Provider **Docker**, image `nginx:1.27-alpine`.
4. **Advanced, Volumes, Add**, choose **File Mount**:
   - Mount path: `/usr/share/nginx/html/index.html`
   - Content: paste all of `index.html` from this folder
5. **Domains, Add**: container port `80`. Give it a host name, or use the
   generated one Dokploy offers.
6. **Deploy**.

The File Mount is why no git repo is needed: Dokploy writes the file into the
container for you. Confirmed present in v0.30.2
(`components/dashboard/application/advanced/volumes/add-volumes.tsx`).
