FROM staticfloat/nginx-certbot

# Accept FQDN parameter from caller
ARG FQDN

# Copy nginx.conf to /etc/nginx/conf.d/
ADD nginx.conf /etc/nginx/conf.d/${FQDN}.conf

# Replace all instances of {FQDN} within the configuration file
RUN sed -i "s/{FQDN}/${FQDN}/g" /etc/nginx/conf.d/${FQND}.conf
