############################
# PLATFORM-Variablen (vom AppStore gesetzt)
############################

variable "image_name" {
  type        = string
  description = "Glance-Image-Name — vom Worker zur Build-Zeit gesetzt. @platform:internal"
  default     = "kubernetes-app-vX"
}

variable "networks" {
  type        = list(string)
  description = "@openstack:network:id:list"
  default     = ["9b579624-d844-4df3-b38d-89978b31d37d"]
}

variable "security_groups" {
  type        = list(string)
  description = "@openstack:security_group:id:list"
  default     = ["5c0e96fb-bd1f-41b3-b400-deccf7712a80"]
}

############################
# APP-Variablen
############################

variable "k3s_version" {
  type        = string
  description = "k3s-Release, das ins Image installiert wird. @platform:internal"
  default     = "v1.31.4+k3s1"
}

variable "student_image" {
  type        = string
  description = "Name und Tag des Student-Images (muss zu LAB_IMAGE in labctl passen). @platform:internal"
  default     = "kubernetes-app/student:1"
}
