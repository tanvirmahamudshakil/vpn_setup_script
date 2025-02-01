#!/bin/bash

# Script to install and set up Node.js on a VPS

echo "Updating package list..."
sudo apt update

echo "Installing required dependencies..."
sudo apt install -y curl

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash

source ~/.bashrc

nvm list-remote

sudo nvm install v20.18.0

echo "Verifying Node.js installation..."
sudo node -v
sudo npm -v



sudo npm i pm2 -g

echo "Installing Nginx..."
sudo apt install -y nginx

cat <<EOL > default.conf
server {
        listen 80 default_server;
        listen [::]:80 default_server;

        root /var/www/html;
        index index.html index.htm index.nginx-debian.html;

        server_name _;

        location / {
                proxy_http_version 1.1;
                proxy_cache_bypass $http_upgrade;

                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection 'upgrade';
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;

                proxy_pass http://localhost:3002;
        }

}
EOL

# Move and enable Nginx config
sudo mv default.conf /etc/nginx/sites-available/default

echo "Restarting Nginx..."
sudo systemctl restart nginx

# Install UFW
echo "Installing UFW..."
sudo apt install -y ufw

echo "Configuring UFW..."

# Allow OpenSSH and Nginx Full
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw allow 22

# Enable UFW
sudo ufw enable

echo "Setup complete. Your Node.js app should be available through Nginx at your_domain_or_ip."
echo "Firewall (UFW) is now active and allowing OpenSSH and Nginx."

sudo systemctl restart nginx

echo "Installing Nano..."
sudo apt install -y nano


# Install WireGuard
echo "Installing WireGuard..."
sudo apt install -y wireguard
echo "WireGuard has been installed."


# Install Git
echo "Installing Git..."
sudo apt install -y git


# echo "back root folder"
# cd ..

# Clone a Git repository
echo "Cloning a sample Git repository..."
git clone https://github.com/tanvirmahamudshakil/wareguard_api.git



# inter wireguard folder
echo "enter ewireguard api..."
cd wareguard_api

echo "init npm"
npm install

echo "start server.mjs"
pm2 start server.mjs