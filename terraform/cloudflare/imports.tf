# Adopt the manually-created record instead of creating a duplicate.
# Terraform plans only the attributes that differ from the live record, so
# after the import, `terraform plan` should show no change to the record.
import {
  to = cloudflare_dns_record.quote_api
  id = "${var.zone_id}/${var.existing_dns_record_id}"
}
