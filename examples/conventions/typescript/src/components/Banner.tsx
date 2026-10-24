export function Banner({ notice }: { notice: Notice }) {
  const { t } = useTranslation();
  return (
    <div role="status">
      <strong>Heads up!</strong> {t(notice.messageKey)}
    </div>
  );
}
