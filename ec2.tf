data "aws_ami" "amazon_linux" {

  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "app_lt" {

  name_prefix   = "app-server-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [
    aws_security_group.app_ec2_sg.id
  ]

  user_data = base64encode(<<-EOF
#!/bin/bash

dnf install -y python3 python3-pip

mkdir -p /opt/app

cat > /opt/app/index.html <<'HTML'
${file("${path.module}/app/index.html")}
HTML

python3 -m venv /opt/app/venv

/opt/app/venv/bin/pip install mysql-connector-python

cat > /opt/app/server.py <<'PY'
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import mysql.connector

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Healthy")
            return

        if self.path == "/db":
            try:
                connection = mysql.connector.connect(
                    host=os.environ["DB_HOST"],
                    user=os.environ["DB_USER"],
                    password=os.environ["DB_PASSWORD"],
                    database=os.environ["DB_NAME"],
                    port=3306,
                    connection_timeout=5
                )

                cursor = connection.cursor()
                cursor.execute("SELECT 1")
                result = cursor.fetchone()

                cursor.close()
                connection.close()

                self.send_response(200)
                self.end_headers()
                self.wfile.write(
                    f"RDS MySQL Connected: {result}".encode()
                )

            except Exception:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b"Database connection failed")

        else:
    try:
        with open("/opt/app/index.html", "rb") as file:
            html = file.read()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    except Exception:
        self.send_response(500)
        self.end_headers()
        self.wfile.write(b"Welcome page not found")

HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

cat > /etc/systemd/system/app.service <<'SERVICE'
[Unit]
Description=Three Tier Application
After=network.target

[Service]
Environment="DB_HOST=${aws_db_instance.main.address}"
Environment="DB_USER=${var.db_username}"
Environment="DB_PASSWORD=${var.db_password}"
Environment="DB_NAME=applicationdb"
ExecStart=/opt/app/venv/bin/python /opt/app/server.py
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

chmod 600 /etc/systemd/system/app.service

systemctl daemon-reload
systemctl enable --now app.service

EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "Application-EC2"
      Tier = "Application"
    }
  }

}

resource "aws_launch_template" "web_lt" {

  name_prefix   = "web-server-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [
    aws_security_group.web_ec2_sg.id
  ]

  user_data = base64encode(<<-EOF
#!/bin/bash

dnf install -y nginx

cat > /etc/nginx/conf.d/app.conf <<'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://${aws_lb.internal_alb.dns_name}:8080;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX

nginx -t
systemctl enable --now nginx
systemctl restart nginx

EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "Web-EC2"
      Tier = "Web"
    }
  }

}