class ArchiveProject
  def call(project)
    if project.archived?
      raise ArgumentError, "project #{project.id} is already archived; call RestoreProject first to change it"
    end

    project.update!(archived_at: Time.current)
    ArchiveNotificationJob.perform_later(project.id)
    Result.success(project)
  end
end
